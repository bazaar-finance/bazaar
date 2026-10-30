// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {AdlLib} from "../../src/libraries/AdlLib.sol";
import {BucketLib} from "../../src/libraries/BucketLib.sol";
import {LiquidationLib} from "../../src/libraries/LiquidationLib.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";

/// @dev Copy of the AdlHarness pattern (LiquidationVaultTest) for the untested AdlLib arms.
contract AdlEdgeHarness {
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

    /// @dev The funding index a position entered at; one at the live index carries no funding of
    ///      its own.
    function setBucketFundingIndex(address user, int256 idx) external {
        positionBuckets[user].entryFundingIndex = idx;
    }

    function setPendingLiq(uint256 size, uint256 bankruptcyNotional, bool isLong) external {
        vault.pendingLiqSize = size;
        vault.pendingLiqBankruptcyNotional = bankruptcyNotional;
        vault.pendingLiqEntryNotional = bankruptcyNotional;
        vault.pendingLiqIsLong = isLong;
        vault.pendingLiqSeized = 0;
    }

    /// @dev Stage an entry basis away from the bankruptcy notional: the gap is staged as the
    ///      collateral seized with the inventory.
    function setPendingLiqEntryNotional(uint256 x) external {
        vault.pendingLiqEntryNotional = x;
        uint256 bk = vault.pendingLiqBankruptcyNotional;
        vault.pendingLiqSeized = x > bk ? x - bk : bk - x;
    }

    /// @dev Stage the collateral seized with the inventory on its own, for an estate whose entry
    ///      and bankruptcy notionals are also apart by the funding it took before liquidation.
    function setPendingLiqSeized(uint256 x) external {
        vault.pendingLiqSeized = x;
    }

    /// @dev What the deposits ledger owes the fund: collections it could not pay.
    function setLedgerArrears(uint256 x) external {
        vault.ledgerArrears = x;
    }

    function arrears() external view returns (uint256) {
        return vault.ledgerArrears;
    }

    /// @dev The trailing minimum of per-side open interest the reserve is sized on; live open
    ///      interest above it closes without releasing any reserve.
    function setTrailingOi(uint128 x) external {
        vault.trailingOiSize = x;
    }

    /// @dev The insurance target ratio the pair would have cached: the reserve the ADL gate and
    ///      the batch sizing net out of the fund is derived from it.
    function setTargetRatio(uint256 bp) external {
        vault.targetInsuranceRatioBp = bp;
    }

    function setVaultInsurance(uint256 x) external {
        vault.insuranceFundBalance = x;
    }

    function setPendingLiqFundingIndex(int256 idx) external {
        vault.pendingLiqEntryFundingIndex = idx;
    }

    function setVaultCollateral(uint256 x) external {
        vault.totalCollateralDeposited = x;
    }

    function setOI(uint256 longOI, uint256 shortOI, uint256 longSum, uint256 shortSum) external {
        vault.totalLongOI = longOI;
        vault.totalShortOI = shortOI;
        vault.longWeightedEntrySum = longSum;
        vault.shortWeightedEntrySum = shortSum;
    }

    // -------- ADL window-deposit state (epoch-tagged score freeze) --------
    uint64 public adlEpoch;
    mapping(address => uint64) internal adlDepositEpoch;
    mapping(address => uint256) internal adlWindowDeposits;

    function setAdlEpoch(uint64 e) external {
        adlEpoch = e;
    }

    function setWindowDeposit(address user, uint64 epoch, uint256 amount) external {
        adlDepositEpoch[user] = epoch;
        adlWindowDeposits[user] = amount;
    }

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

    function execAdlBoth(
        address[] calldata winners,
        address[] calldata deferredWinners,
        BazaarTypes.AdlParams calldata params
    ) external returns (BazaarTypes.AdlResult memory) {
        return AdlLib.executeAdlCore(
            orders,
            book,
            positionBuckets,
            vault,
            feeEscrow,
            deferred,
            winners,
            deferredWinners,
            params,
            adlEpoch,
            adlDepositEpoch,
            adlWindowDeposits
        );
    }

    /// @dev liquidate()'s seizure path on the staged book: the netting gate, the seizure and,
    ///      against an opposite inventory, the netting.
    /// @param user The account to liquidate
    /// @param price The liquidation price
    /// @param fundingIndex The live funding index
    /// @return The accounts seized and deferred, and the walk's credit
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
                marginReqs: BazaarTypes.MarginRequirements({
                    imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0
                }),
                pairId: bytes32(uint256(0xADE)),
                currentBlock: uint64(block.number)
            })
        );
    }

    function pushDeferred(address user) external {
        deferred.push(user);
    }

    function deferredCount() external view returns (uint256) {
        return deferred.length;
    }

    function pendingIsLong() external view returns (bool) {
        return vault.pendingLiqIsLong;
    }

    function claimable(address who) external view returns (uint256) {
        return feeEscrow.claimable[who];
    }

    function deficit() external view returns (uint256) {
        return vault.deficit;
    }

    function bucketSize(address u) external view returns (uint256) {
        return positionBuckets[u].size;
    }

    function bucketEntry(address u) external view returns (uint256) {
        return positionBuckets[u].entryValue;
    }

    function bucketCollateral(address u) external view returns (uint256) {
        return positionBuckets[u].collateral;
    }

    function insurance() external view returns (uint256) {
        return vault.insuranceFundBalance;
    }

    function vaultCollateral() external view returns (uint256) {
        return vault.totalCollateralDeposited;
    }

    function pendingSize() external view returns (uint256) {
        return vault.pendingLiqSize;
    }

    function shortOI() external view returns (uint256) {
        return vault.totalShortOI;
    }

    function longOI() external view returns (uint256) {
        return vault.totalLongOI;
    }

    function shortSum() external view returns (uint256) {
        return vault.shortWeightedEntrySum;
    }

    /// @dev The ADL gate's figures for the staged vault, so a test can check the release
    ///      condition a batch is sized to.
    function exposure(uint256 price, int256 fundingIndex, uint256 mmrBp)
        external
        view
        returns (uint256 expectedLoss, uint256 base, uint256 worstFinish, uint256 shortfall)
    {
        return RiskParamsLib.vaultAdlExposure(vault, price, fundingIndex, mmrBp);
    }

    /// @dev The netting gate on `user`'s position against the staged inventory, with `keep` the
    ///      inventory the netting must leave backed.
    function nettingAffordable(address user, uint256 price, int256 fundingIndex, uint256 keep)
        external
        view
        returns (bool)
    {
        BazaarTypes.MarginRequirements memory zeroReqs;
        BazaarTypes.BucketState memory state =
            BucketLib.calculateState(positionBuckets[user], price, fundingIndex, zeroReqs);
        return LiquidationLib.nettingAffordable(vault, state, price, fundingIndex, keep);
    }

    /// @dev What the fund holds for a close of the whole inventory at the estates' bankruptcy
    ///      price, as the netting gate reads it — free capital above the reserve plus the
    ///      arrears — and what that close needs beyond the inventory's earmark.
    function survivorBacking(uint256 price, int256 fundingIndex)
        external
        view
        returns (uint256 backing, uint256 needed)
    {
        uint256 free = RiskParamsLib.insuranceFreeCapital(vault);
        uint256 reserve = RiskParamsLib.adlReserve(vault, price);
        backing = (free > reserve ? free - reserve : 0) + vault.ledgerArrears;
        needed = RiskParamsLib.bankruptcyCloseCost(vault, fundingIndex);
    }

    /// @dev The fund's balance less the inventory's earmark.
    function freeCapital() external view returns (uint256) {
        return RiskParamsLib.insuranceFreeCapital(vault);
    }
}

/// @notice AdlLib arms with no prior coverage: the partial-close of an oversized winner (which
///         rewrites a live user's collateral/size/entry), descending-score ordering, the in-auction
///         score threshold, the negative-settlement skip, and the input guards.
contract AdlEdgeTest is Test {
    uint256 constant SCALE = 1e18;
    /// @dev How far, in wei, the netting gate's pro-rata figures, read before a netting, can sit
    ///      from the payment's, read once the netting has reduced the aggregate: the surviving
    ///      inventory's need, or after a flip the new inventory's and the netted share of the
    ///      account's collateral.
    uint256 constant NETTING_ROUNDING = 100;
    AdlEdgeHarness h;
    address winner = makeAddr("winner");
    address loser = makeAddr("loser");
    address loser2 = makeAddr("loser2");
    address ally = makeAddr("ally");
    address ally2 = makeAddr("ally2");

    function setUp() public {
        h = new AdlEdgeHarness();
        vm.warp(1_700_000_000);
        h.setVaultInsurance(1_000e18);
        h.setVaultCollateral(1_000e18);
    }

    /// @dev Vault holds LONGS -> deleverage side is SHORTS (adlLongs=false). Threshold collapsed
    ///      to 1 unless snapshotAgeMinutes overrides the auction clock.
    function _params(uint256 snapshotPrice, uint256 elapsedMinutes)
        internal
        view
        returns (BazaarTypes.AdlParams memory)
    {
        return BazaarTypes.AdlParams({
            adlLongs: false,
            adlSnapshotPrice: snapshotPrice,
            adlSnapshotFundingIndex: 0,
            adlAuctionStartTs: block.timestamp - elapsedMinutes * 1 minutes,
            currentPrice: snapshotPrice,
            currentFundingIndex: 0,
            marginRequirements: BazaarTypes.MarginRequirements({
                imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0
            }),
            pairId: bytes32(uint256(0xADE)),
            adlId: 0,
            currentBlock: uint64(block.number)
        });
    }

    /// @dev Same, with the live mark held apart from the frozen snapshot. The batch's size cap
    ///      reads the mark, and settlement takes it when it sits on the fund's favorable side of
    ///      the bankruptcy price; dropping it below the bankruptcy price puts the vault in the
    ///      loss that makes a deleverage warranted without disturbing ranking or settlement.
    function _paramsAtMark(uint256 snapshotPrice, uint256 mark, uint256 elapsedMinutes)
        internal
        view
        returns (BazaarTypes.AdlParams memory p)
    {
        p = _params(snapshotPrice, elapsedMinutes);
        p.currentPrice = mark;
    }

    function _one(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    // ---------------- partial close of an oversized winner ----------------

    /// @notice A winner larger than the vault's pending exposure is PARTIALLY closed: pro-rata
    ///         entry reduction, realized PnL credited to collateral, position left open, and
    ///         insurance and the deposits ledger untouched when the inventory closes at its own
    ///         basis.
    function test_partialClose_oversizedWinner_proRataAndConserved() public {
        // Vault long 1 unit at bankruptcy $100/u -> settlement price $100.
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        // Short winner, 2 units entered at $150/u, $10 collateral; +$100 PnL at snapshot $100.
        h.setBucket(winner, false, 2 * SCALE, 300 * SCALE, 10 * SCALE);
        h.setOI(0, 2 * SCALE, 0, 300 * SCALE);
        // An empty fund can finish nothing inside the band, so the batch is required to close
        // the whole aggregate and the winner's size is what makes the close partial.
        h.setVaultInsurance(0);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _paramsAtMark(100 * SCALE, 90 * SCALE, 15));

        assertEq(r.settlementPrice, 100 * SCALE, "settlement = bankruptcy notional / size");
        assertEq(r.totalLiqSize, 1 * SCALE, "only the vault's exposure closed");
        assertEq(h.bucketSize(winner), 1 * SCALE, "half the position remains open");
        assertEq(h.bucketEntry(winner), 150 * SCALE, "entry reduced pro-rata");
        // Realized PnL on the closed half: 100/2 = 50, credited on top of raw collateral 10.
        assertEq(h.bucketCollateral(winner), 60 * SCALE, "collateral += realized partial PnL");
        // Entry and bankruptcy notional coincide (nothing was seized) and no funding accrued, so
        // the inventory slice realizes zero: the credit is backed by the ledger, not the fund.
        // The untouched deposits ledger is what proves it — a credit charged to the fund would
        // move it by the $50 the winner was paid.
        assertEq(h.insurance(), 0, "inventory closed at its own basis: insurance untouched");
        assertEq(h.vaultCollateral(), 1_000e18, "no vault realization: deposits ledger untouched");
        assertEq(h.pendingSize(), 0, "vault exposure cleared");
        assertEq(h.shortOI(), 1 * SCALE, "closed half removed from OI");
        assertEq(h.shortSum(), 150 * SCALE, "closed entry removed from weighted sum");
    }

    // ---------------- batch cap: only the size that restores the fund is closed ----------------

    /// @dev 1000 units of inherited long inventory: the estates entered at $100 and went bankrupt
    ///      at $90, so the fund holds $10/unit of seized collateral, and the mark is $80. One
    ///      short winner entered at $150 covers the entire aggregate on their own.
    function _oversizedWinnerOnDeepInventory() internal {
        h.setPendingLiq(1000 * SCALE, 90_000 * SCALE, true); // settlement price = $90
        h.setPendingLiqEntryNotional(100_000 * SCALE); // seizure = $10,000
        h.setVaultCollateral(1_000_000e18);
        h.setBucket(winner, false, 1000 * SCALE, 150_000 * SCALE, 1_000 * SCALE);
        h.setOI(0, 1000 * SCALE, 0, 150_000 * SCALE);
    }

    /// @notice A winner large enough to cover the whole aggregate is closed only for the size the
    ///         exposure requires. Finishing the 1000 units at the band edge ($76, the $80 mark
    ///         less the 5% band) would cost $14,000 against $12,000 of free capital, so the batch
    ///         must close $2,000 of that; each unit closed removes $14 of it and hands the executor
    ///         $0.01 of it back, leaving 143 units to close and 857 with the winner. Bounding by
    ///         winner count instead would settle all 1000 at the estates' bankruptcy price and pay
    ///         the executor a cut of every one.
    function test_batchCap_flatFunding_closesOnlyWhatTheExposureRequires() public {
        _oversizedWinnerOnDeepInventory();
        h.setVaultInsurance(22_000e18); // free capital = 22,000 − 10,000 seized

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _paramsAtMark(90 * SCALE, 80 * SCALE, 15));

        assertApproxEqRel(r.totalLiqSize, 142.9593e18, 0.0001e18, "2,000 excess / 13.99 per unit");
        assertEq(h.bucketSize(winner), 1000 * SCALE - r.totalLiqSize, "the rest stays with the winner");
        assertEq(h.pendingSize(), 1000 * SCALE - r.totalLiqSize, "and the matching inventory stays open");
    }

    /// @notice Every unit closed leaves both sides of the book, so the reserve on it returns to the
    ///         base as the batch runs and the batch needs fewer units than the finish cost alone
    ///         implies. With a 5% target the reserve is $0.40 per unit of open interest here:
    ///         $400 on the 1000-unit book, so the base is $11,600 rather than $12,000, and each
    ///         unit closed repairs $14.39 rather than $13.99 — 167 units instead of 172.
    function test_batchCap_reserveReleasedByTheCloseShortensTheBatch() public {
        _oversizedWinnerOnDeepInventory();
        h.setVaultInsurance(22_000e18); // free capital = 12,000
        h.setTargetRatio(500); // 5% of the $80,000 book → reserve $400

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _paramsAtMark(90 * SCALE, 80 * SCALE, 15));

        assertApproxEqRel(r.totalLiqSize, 166.7825e18, 0.0001e18, "2,400 excess / 14.39 per unit");
        assertLt(r.totalLiqSize, 172 * SCALE, "sizing without the released reserve would close 172");
    }

    /// @notice Right at the release boundary almost nothing needs closing. Free capital of $13,999
    ///         sits $1 under the $14,000 it would take to finish at the band edge, so seven
    ///         hundredths of a unit restores the fund — while the same winner, unbounded, would
    ///         have been settled for all 1000.
    function test_batchCap_atTheBoundary_closesAlmostNothing() public {
        _oversizedWinnerOnDeepInventory();
        h.setVaultInsurance(23_999e18); // free capital = 13,999 -> $1 short of the band edge

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _paramsAtMark(90 * SCALE, 80 * SCALE, 15));

        assertApproxEqRel(r.totalLiqSize, 0.07148e18, 0.01e18, "$1 excess / 13.99 per unit");
        assertLt(r.totalLiqSize, 10 * SCALE, "a boundary breach does not deleverage the book");
    }

    /// @notice The funding the vault owes on the inventory it holds is part of the cap. It leaves
    ///         the fund as each unit settles, so the base descends with it and the batch has to
    ///         close further than the finish cost alone implies: 214 units here, where sizing
    ///         against the finish cost alone would stop at 200 and leave the auction pending.
    function test_batchCap_carryPushesTheCloseFurther() public {
        _oversizedWinnerOnDeepInventory();
        h.setVaultInsurance(22_000e18);
        h.setPendingLiqFundingIndex(0);

        // Index +1: the vault's long inventory owes $1/unit, $1,000 across the aggregate.
        BazaarTypes.AdlParams memory params = _paramsAtMark(90 * SCALE, 80 * SCALE, 15);
        params.currentFundingIndex = int256(1 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), params);

        assertApproxEqRel(r.totalLiqSize, 214.4389e18, 0.0001e18, "3,000 excess / 13.99 per unit");
        assertGt(r.totalLiqSize, 200 * SCALE, "sizing against the finish cost alone would stop at 200");
    }

    /// @notice When the figure exceeds the inventory the cap does not bind: the batch runs to its
    ///         eligible size. Vault long 100 units marked $10 ABOVE the bankruptcy price but owing
    ///         $20/unit of funding, with $100 in the fund against a $1,550 band-edge finish cost:
    ///         each unit closed at the $110 mark frees $5.50 ($15.50 of finish cost less the $10
    ///         it costs past the earmark), so 264 would be needed.
    function test_batchCap_figureBeyondTheInventory_closesTheEligibleSize() public {
        h.setPendingLiq(100 * SCALE, 10_000 * SCALE, true); // settlement price = $100, nothing seized
        h.setVaultInsurance(100e18);
        h.setPendingLiqFundingIndex(0);
        h.setBucket(winner, false, 100 * SCALE, 15_000 * SCALE, 100 * SCALE);
        h.setOI(0, 100 * SCALE, 0, 15_000 * SCALE);

        BazaarTypes.AdlParams memory params = _paramsAtMark(100 * SCALE, 110 * SCALE, 15);
        params.currentFundingIndex = int256(20 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), params);

        assertEq(r.totalLiqSize, 100 * SCALE, "the whole eligible size closes");
        assertEq(h.pendingSize(), 0, "vault exposure cleared");
    }

    /// @dev Long 10 @ $100 against $200 seized, the estates having paid $5 a unit of funding
    ///      before liquidation: bankrupt at $85. Mark $80, band edge $76, $40 in the fund above
    ///      the earmark, no reserve; one short winner, 10 @ $110.
    function _paidFundingSetup() internal {
        h.setPendingLiq(10 * SCALE, 850 * SCALE, true);
        h.setPendingLiqEntryNotional(1000 * SCALE);
        h.setPendingLiqSeized(200 * SCALE);
        h.setPendingLiqFundingIndex(0);
        h.setVaultInsurance(240e18);
        h.setBucket(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 1100 * SCALE);
    }

    /// @dev The batch parameters at `mark` with the live index at `idx` since the estates' entry.
    function _paramsAtIndex(uint256 mark, int256 idx) internal view returns (BazaarTypes.AdlParams memory p) {
        p = _paramsAtMark(100 * SCALE, mark, 15);
        p.currentFundingIndex = idx;
        p.adlSnapshotFundingIndex = idx;
    }

    /// @notice The funding the estates paid before liquidation is inside the bankruptcy price, so
    ///         a close there costs the fund nothing past the earmark: the batch closes the 5.56
    ///         units that put the fund on the release line — the $90 band-edge finish cost less
    ///         its $40, plus the rounding allowance, over the $8.995 a unit a close at $85 frees
    ///         ($9 of finish cost less the cut on the $5 averted) — and no more.
    function test_batchCap_paidPreLiquidationFunding_landsOnTheLine() public {
        _paidFundingSetup();
        int256 idx = int256(5 * SCALE);
        uint256 expected = Math.mulDiv(50.000001e18, 10 * SCALE, 89.95e18, Math.Rounding.Ceil);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _paramsAtIndex(80 * SCALE, idx));

        assertEq(r.settlementPrice, 85 * SCALE, "the bankruptcy price");
        assertEq(r.totalLiqSize, expected, "5.56 units");
        (, uint256 base, uint256 worstFinish,) = h.exposure(80 * SCALE, idx, 1_000);
        assertLe(worstFinish, base, "on the release line");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        // $20 a unit paid at $85, all of it earmark: free capital moves only by the executor's cut.
        assertApproxEqAbs(
            h.insurance(),
            240e18 - Math.mulDiv(expected, 20e18, SCALE) - h.claimable(address(this)),
            1e3,
            "the fund paid nothing past the earmark"
        );
    }

    /// @notice The mirror with the funding received: $5 a unit the estates took before liquidation
    ///         lowers the bankruptcy price to $75 and is no gain on the close. At the $70 mark the
    ///         batch closes the 5.30 units that put the fund on the release line — the $85 finish
    ///         cost less its $40, plus the allowance, over $8.495 a unit — in one batch.
    function test_batchCap_receivedPreLiquidationFunding_landsOnTheLine() public {
        _paidFundingSetup();
        h.setPendingLiq(10 * SCALE, 750 * SCALE, true);
        h.setPendingLiqEntryNotional(1000 * SCALE);
        h.setPendingLiqSeized(200 * SCALE);
        int256 idx = -int256(5 * SCALE);
        uint256 expected = Math.mulDiv(45.000001e18, 10 * SCALE, 84.95e18, Math.Rounding.Ceil);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _paramsAtIndex(70 * SCALE, idx));

        assertEq(r.settlementPrice, 75 * SCALE, "the bankruptcy price");
        assertEq(r.totalLiqSize, expected, "5.30 units");
        (, uint256 base, uint256 worstFinish,) = h.exposure(70 * SCALE, idx, 1_000);
        assertLe(worstFinish, base, "on the release line");
        assertEq(h.deficit(), 0, "nothing went unpaid");
    }

    /// @notice Arrears left behind by earlier inventory are a receivable a close reaches only
    ///         once its own earmark is spent, not backing that shrinks with the inventory. Long 10
    ///         @ $100 against $150 seized, bankrupt at $85, with $20 of such arrears: at the $80
    ///         mark the batch closes the 3.34 units that put the fund on the release line — the
    ///         $90 finish cost less the fund's $40 and the $20, plus the allowance, over $8.995 a
    ///         unit — and the arrears stay, since each unit's $15 loss at $85 is exactly its
    ///         earmark.
    function test_batchCap_leftoverArrears_landsOnTheLine() public {
        h.setPendingLiq(10 * SCALE, 850 * SCALE, true);
        h.setPendingLiqEntryNotional(1000 * SCALE);
        h.setLedgerArrears(20e18);
        h.setVaultInsurance(190e18);
        h.setBucket(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 1100 * SCALE);
        uint256 expected = Math.mulDiv(30.000001e18, 10 * SCALE, 89.95e18, Math.Rounding.Ceil);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _paramsAtMark(100 * SCALE, 80 * SCALE, 15));

        assertEq(r.totalLiqSize, expected, "3.34 units");
        assertEq(h.arrears(), 20e18, "the close's own earmark covered it: the arrears stay owed");
        (, uint256 base, uint256 worstFinish,) = h.exposure(80 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "on the release line");
        // $15 a unit paid at $85, all of it in cash from the closed units' earmark.
        assertApproxEqAbs(
            h.insurance(),
            190e18 - Math.mulDiv(expected, 15e18, SCALE) - h.claimable(address(this)),
            1e3,
            "the earmark paid the whole close"
        );
    }

    // ---------------- funding: vault leg settles once, winner tab rides in the credit ----------------

    /// @notice The inventory's funding is the vault's own leg, settled into insurance from the
    ///         liquidatees' entry index to the live index. The winner's tab is part of the
    ///         winner's credit and is backed by the deposits ledger like the rest of it, so the
    ///         fund moves by the vault's leg alone, not by the winner's PnL.
    function test_adlClose_vaultFundingLegSettlesOnce_winnerTabInCredit() public {
        // Vault long 2 units at bankruptcy $100/u; liquidatee's entry funding index 0. The winner
        // covers one of them, so the close is sized by the winner rather than by the batch cap.
        h.setPendingLiq(2 * SCALE, 200 * SCALE, true);
        h.setPendingLiqFundingIndex(0);
        // Short winner, 1 unit entered at $150/u, $10 collateral, entry funding index 0.
        h.setBucket(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);
        // The $4 fund is the whole exposure here: nothing was seized, so the only loss the vault
        // carries is the $4 of funding its 2 units owe at the live index.
        h.setVaultInsurance(4e18);

        // Index delta +2: shorts are owed $2/unit; the vault's long inventory is the payer.
        BazaarTypes.AdlParams memory params = BazaarTypes.AdlParams({
            adlLongs: false,
            adlSnapshotPrice: 100 * SCALE,
            adlSnapshotFundingIndex: int256(2 * SCALE),
            adlAuctionStartTs: block.timestamp - 15 minutes,
            currentPrice: 100 * SCALE,
            currentFundingIndex: int256(2 * SCALE),
            marginRequirements: BazaarTypes.MarginRequirements({
                imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0
            }),
            pairId: bytes32(uint256(0xADE)),
            adlId: 0,
            currentBlock: uint64(block.number)
        });

        h.execAdl(_one(winner), params);

        // Winner credit: price PnL (150−100) + own funding receivable (+2) = $52, in full. The
        // vault's leg on the slice is the $2 the long inventory owed (entry and bankruptcy
        // notional coincide, so the price leg is zero): that is the only insurance entry.
        assertEq(h.bucketCollateral(winner), 62 * SCALE, "winner paid totalPnl incl. funding");
        assertEq(h.insurance(), 4e18 - 2e18, "insurance settles the vault's funding leg once");
        assertEq(h.vaultCollateral(), 1_000e18 + 2e18, "deposits ledger mirrors the single I->D transfer");
        assertEq(h.pendingSize(), 1 * SCALE, "the unit the winner could not cover stays open");
    }

    /// @notice Pre-liquidation funding is not booked twice. The estate had received $2 of
    ///         funding by liquidation, which the bankruptcy price embeds (bk = 100 − 10 − 2 =
    ///         88), and the index moved a further $1 in the vault's favor while it held the
    ///         inventory. The vault's leg runs from the estate's ENTRY: price 88 − 100 = −12,
    ///         funding +3, net −$9. The $2 enters the price leg with one sign and the funding
    ///         leg with the other, leaving the $10 seizure less the $1 window receivable. The
    ///         winner (entered at the same price and index) is credited price(100 − 88) + own
    ///         tab(−3) = $9, so both sides agree and insurance nets +$1 against its seizure.
    function test_adlClose_preAndWindowFunding_noDoubleCount() public {
        // Estate: two such longs, each entry $100, collateral $10, $2 received by liquidation →
        // bk $88/u. The winner covers one, so the close is sized by the winner, not the batch cap.
        h.setPendingLiq(2 * SCALE, 176 * SCALE, true);
        h.setPendingLiqEntryNotional(200 * SCALE);
        h.setPendingLiqFundingIndex(0); // the estate's entry index
        // Winner: short 1 unit, entry $100, $5 collateral, entry funding index 0.
        h.setBucket(winner, false, 1 * SCALE, 100 * SCALE, 5 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 100 * SCALE);
        // The fund holds exactly the $24 it seized off the two estates and nothing beyond it, so
        // there is no free capital and the batch cap does not bind before the winner's size does.
        h.setVaultInsurance(24e18);

        // Index fell 3 since entry (−2 before liquidation, −1 during the vault's window):
        // longs (estate, then vault) received; shorts (winner) paid.
        BazaarTypes.AdlParams memory params = BazaarTypes.AdlParams({
            adlLongs: false,
            adlSnapshotPrice: 88 * SCALE,
            adlSnapshotFundingIndex: -int256(3 * SCALE),
            adlAuctionStartTs: block.timestamp - 15 minutes,
            currentPrice: 80 * SCALE, // mark below the bankruptcy price: the vault is in real loss
            currentFundingIndex: -int256(3 * SCALE),
            marginRequirements: BazaarTypes.MarginRequirements({
                imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0
            }),
            pairId: bytes32(uint256(0xADE)),
            adlId: 0,
            currentBlock: uint64(block.number)
        });

        h.execAdl(_one(winner), params);

        // Credit = (100 − 88) − 3 = $9 on top of $5 collateral.
        assertEq(h.bucketCollateral(winner), 14 * SCALE, "winner credited price leg less own tab");
        // Less the executor's 0.1% of the $8 the close averted against the $80 mark.
        assertEq(h.insurance(), 24e18 - 9e18 - 0.008e18, "vault leg from entry: -12 price + 3 funding, booked once");
        assertEq(h.vaultCollateral(), 1_000e18 + 9e18, "deposits ledger mirrors the single transfer");
        assertEq(h.pendingSize(), 1 * SCALE, "the estate the winner could not cover stays open");
    }

    // ---------------- window-deposit score freeze (ADL queue dodging) ----------------

    /// @notice A deposit made DURING the live ADL window is subtracted from the scoring
    ///         collateral: the winner ranks on their pre-window book (here $1 → score 50e18,
    ///         eligible even at the near-max early-auction threshold), while settlement and the
    ///         payout still use their REAL post-deposit collateral. Mid-auction top-ups protect
    ///         the account; they cannot re-rank the queue.
    function test_windowDeposit_cannotDodgeAdlQueue() public {
        // Vault long 2 units at bankruptcy $100/u, marked at $90: a $20 loss against a $10 fund,
        // so the batch cap leaves room for more than the one unit the winner can cover.
        h.setPendingLiq(2 * SCALE, 200 * SCALE, true);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);
        h.setVaultInsurance(10e18);
        // Short winner: entry $150, pnl $50 at the $100 settlement. Real collateral $60 — of
        // which $59 was deposited during THIS window (epoch 7) to dodge: raw score would be
        // 50/60 ≈ 0.83e18, far below the early-auction threshold.
        h.setBucket(winner, false, 1 * SCALE, 150 * SCALE, 60 * SCALE);
        h.setAdlEpoch(7);
        h.setWindowDeposit(winner, 7, 59 * SCALE);

        // 1 minute into the auction: threshold is near max (~25e18) — only the frozen
        // pre-window score (50e18 on $1) clears it.
        h.execAdl(_one(winner), _paramsAtMark(100 * SCALE, 90 * SCALE, 1));

        assertEq(h.bucketSize(winner), 0, "dodger closed despite the top-up");
        assertEq(h.bucketCollateral(winner), (60 + 50) * SCALE, "payout uses REAL collateral + pnl");
        // Closed at its own basis, the inventory moves the fund only by the executor's 0.1% of
        // the $10 the close averted against the $90 mark.
        assertEq(h.insurance(), 10e18 - 0.01e18, "inventory closed at its own basis: only the reward leaves");
        assertEq(h.vaultCollateral(), 1_000e18, "no vault realization: deposits ledger untouched");
        assertEq(h.pendingSize(), 1 * SCALE, "the unit the winner could not cover stays open");
    }

    /// @notice The withdraw-to-zero dodge is dead: a winner who pulled ALL collateral out
    ///         (equity gate passes on unrealized PnL alone) floors to 1-wei score collateral —
    ///         effectively infinite score — and is closable from the FIRST minute of the
    ///         auction, at the near-max threshold. Skipping zero-collateral buckets instead of
    ///         flooring them would make exactly these pure-profit accounts ADL-immune.
    function test_withdrawToZero_cannotDodgeAdlQueue() public {
        h.setPendingLiq(2 * SCALE, 200 * SCALE, true);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);
        h.setBucket(winner, false, 1 * SCALE, 150 * SCALE, 0); // all collateral withdrawn
        h.setVaultInsurance(10e18);

        // 1 minute into the auction — only near-infinite scores are eligible, and this is one.
        h.execAdl(_one(winner), _paramsAtMark(100 * SCALE, 90 * SCALE, 1));

        assertEq(h.bucketSize(winner), 0, "pure-profit winner closed first");
        assertEq(h.bucketCollateral(winner), 50 * SCALE, "credit = pnl on zero real collateral");
        // Closed at its own basis, the inventory moves the fund only by the executor's 0.1% of
        // the $10 the close averted against the $90 mark.
        assertEq(h.insurance(), 10e18 - 0.01e18, "inventory closed at its own basis: only the reward leaves");
        assertEq(h.pendingSize(), 1 * SCALE, "the unit the winner could not cover stays open");
    }

    /// @notice A tag from an OLDER window subtracts nothing: the same $59 tagged to epoch 6
    ///         while the current window is epoch 7 leaves the raw score (0.83e18) in force,
    ///         which the early-auction threshold rejects. Lazy epoch invalidation — deposits
    ///         from past windows are ordinary standing collateral.
    function test_windowDeposit_staleEpochTagIgnored() public {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);
        h.setBucket(winner, false, 1 * SCALE, 150 * SCALE, 60 * SCALE);
        h.setAdlEpoch(7);
        h.setWindowDeposit(winner, 6, 59 * SCALE); // previous window's tag

        vm.expectRevert(AdlLib.AdlLib__NoEligibleWinners.selector);
        h.execAdl(_one(winner), _params(100 * SCALE, 1));
    }

    // ---------------- ordering + threshold ----------------

    /// @notice Winners must be submitted in descending ADL-score order.
    function test_ordering_ascendingScoresRevert() public {
        h.setPendingLiq(2 * SCALE, 200 * SCALE, true);
        h.setOI(0, 2 * SCALE, 0, 300 * SCALE);
        address lowScore = makeAddr("lowScore");
        address highScore = makeAddr("highScore");
        // Same +$50 PnL at snapshot $100; scores 1e18 (coll 50) vs 5e18 (coll 10).
        h.setBucket(lowScore, false, 1 * SCALE, 150 * SCALE, 50 * SCALE);
        h.setBucket(highScore, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);

        address[] memory winners = new address[](2);
        winners[0] = lowScore; // ascending -> must revert
        winners[1] = highScore;

        vm.expectPartialRevert(AdlLib.AdlLib__NotDescendingAdlScoreOrder.selector);
        h.execAdl(winners, _params(100 * SCALE, 15));
    }

    /// @notice Mid-auction the quadratic threshold is still high: a modest-score winner is not yet
    ///         eligible (Dutch-auction gating), so the batch reverts with no eligible winners.
    function test_threshold_midAuctionExcludesModestScores() public {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);
        // Score = 50/10 = 5e18. At 5 of 15 minutes elapsed, threshold ~ 1 + 25e18 * (10/15)^2 ~ 11.1e18.
        h.setBucket(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);

        vm.expectRevert(AdlLib.AdlLib__NoEligibleWinners.selector);
        h.execAdl(_one(winner), _params(100 * SCALE, 5));
    }

    // ---------------- ranking freezes the funding index (front-run liveness grief fix) ----------------

    /// @dev Two short winners whose ADL-score ORDER depends on the funding index:
    ///        A: size 1, +$50 at snapshot 100, collateral $10  → frozen score 5e18
    ///        B: size 6, +$30 at snapshot 100, collateral $10  → frozen score 3e18
    ///      At the FROZEN index (0) the descending order is [A, B]. B has the far higher
    ///      size/collateral ratio, so a rise in the LIVE index lifts B's score faster: by
    ///      index +10 the live scores are A=6e18, B=9e18 — order flipped to [B, A]. Before the
    ///      fix, ranking read the live index, so a funding move between the keeper's off-chain
    ///      sort and execution reordered the queue and reverted the descending-order check — a
    ///      cheap ADL-liveness grief. These two tests pin ranking to the FROZEN index.
    function _twoWinnersDivergentFunding() internal returns (address a, address b) {
        // Vault holds longs; deleverage the winning shorts. Exposure 7 units = A(1) + B(6).
        h.setPendingLiq(7 * SCALE, 700 * SCALE, true); // settlement price = 700/7 = 100
        h.setOI(0, 7 * SCALE, 0, (150 + 630) * SCALE);
        a = makeAddr("winnerA");
        b = makeAddr("winnerB");
        h.setBucket(a, false, 1 * SCALE, 150 * SCALE, 10 * SCALE); // +50 @100, coll 10
        h.setBucket(b, false, 6 * SCALE, 630 * SCALE, 10 * SCALE); // +30 @100, coll 10
    }

    /// @notice adlSnapshotFundingIndex is frozen at 0 while the live index has moved to +10.
    ///         Submitting the order that is descending under the FROZEN index [A, B] succeeds:
    ///         ranking ignores the live index, so the batch does not spuriously revert.
    ///         Settlement still uses the live index — the credits include the live funding.
    function test_ranking_frozenFundingIndex_descendingByFrozenSucceeds() public {
        (address a, address b) = _twoWinnersDivergentFunding();

        // The fund holds exactly the $70 of funding the 7 units owe at the live index and nothing
        // beyond it. With no free capital nothing can be finished inside the band, so the batch
        // cap is the whole aggregate and both winners close in full.
        h.setVaultInsurance(70e18);

        BazaarTypes.AdlParams memory params = BazaarTypes.AdlParams({
            adlLongs: false,
            adlSnapshotPrice: 100 * SCALE,
            adlSnapshotFundingIndex: 0, // frozen at auction trigger
            adlAuctionStartTs: block.timestamp - 15 minutes, // threshold collapsed to 1
            currentPrice: 50 * SCALE, // below the $100 bankruptcy price: the vault is in real loss
            currentFundingIndex: int256(10 * SCALE), // live index moved since the trigger
            marginRequirements: BazaarTypes.MarginRequirements({
                imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0
            }),
            pairId: bytes32(uint256(0xADE)),
            adlId: 0,
            currentBlock: uint64(block.number)
        });

        address[] memory winners = new address[](2);
        winners[0] = a; // descending under the FROZEN index
        winners[1] = b;

        BazaarTypes.AdlResult memory r = h.execAdl(winners, params);

        assertEq(r.totalLiqSize, 7 * SCALE, "both winners fully closed, no order revert");
        assertEq(h.bucketSize(a), 0, "A closed");
        assertEq(h.bucketSize(b), 0, "B closed");
        // Settlement uses the LIVE index (+10): A credit = 50 price + 10 funding = 60; B = 30 + 60 = 90.
        assertEq(h.bucketCollateral(a), (10 + 60) * SCALE, "A settled at live funding");
        assertEq(h.bucketCollateral(b), (10 + 90) * SCALE, "B settled at live funding");
        assertEq(h.insurance(), 0, "insurance settled the vault's funding leg on 7 units");
        assertEq(h.vaultCollateral(), 1_000e18 + 70e18, "deposits ledger mirrors the same 7 units of funding");
        assertEq(h.pendingSize(), 0, "vault exposure cleared");
    }

    /// @notice The mirror: the order that is descending under the LIVE index [B, A] REVERTS,
    ///         because ranking scores against the frozen index (A=5e18 > B=3e18), under which
    ///         [B, A] is ascending. This proves the score is keyed to the frozen index, not live —
    ///         so a keeper cannot be griefed into the wrong order by moving live funding.
    function test_ranking_frozenFundingIndex_descendingByLiveReverts() public {
        (address a, address b) = _twoWinnersDivergentFunding();

        BazaarTypes.AdlParams memory params = BazaarTypes.AdlParams({
            adlLongs: false,
            adlSnapshotPrice: 100 * SCALE,
            adlSnapshotFundingIndex: 0,
            adlAuctionStartTs: block.timestamp - 15 minutes,
            currentPrice: 100 * SCALE,
            currentFundingIndex: int256(10 * SCALE),
            marginRequirements: BazaarTypes.MarginRequirements({
                imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0
            }),
            pairId: bytes32(uint256(0xADE)),
            adlId: 0,
            currentBlock: uint64(block.number)
        });

        address[] memory winners = new address[](2);
        winners[0] = b; // descending under LIVE, ascending under FROZEN
        winners[1] = a;

        vm.expectPartialRevert(AdlLib.AdlLib__NotDescendingAdlScoreOrder.selector);
        h.execAdl(winners, params);
    }

    // ---------------- settlement at the mark ----------------

    /// @notice With the mark on the fund's favorable side of the estates' bankruptcy price the
    ///         batch settles at the mark: the winner is credited no better than market and the
    ///         vault's gain on the slice moves from the deposits ledger into the fund. Vault long
    ///         1 unit at bankruptcy $100, marked $104; an empty fund cannot finish the unit
    ///         inside the 5% band, which is what keeps the window open above the neutral price.
    ///         Every part of the unit closed at $104 hands the fund $4 and takes $1.20 of finish
    ///         cost off, so 3/13 of it puts the fund on the release line, and that is all the
    ///         batch closes.
    function test_settlement_markAboveBankruptcy_longInventorySettlesAtMark() public {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        // Short winner, 1 unit entered at $150/u, $10 collateral.
        h.setBucket(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);
        h.setVaultInsurance(0);
        // The $1.20 finish cost plus the rounding allowance, over the $5.20 a unit a close at $104
        // frees: the $4 gain and the $1.20 of finish cost it takes off.
        uint256 closed = Math.mulDiv(1.200001e18, SCALE, 5.2e18, Math.Rounding.Ceil);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _paramsAtMark(100 * SCALE, 104 * SCALE, 15));

        assertEq(r.settlementPrice, 104 * SCALE, "settlement = the mark, not the bankruptcy price");
        assertEq(r.totalLiqSize, closed, "3/13 of the unit");
        // Winner: (150 - 104) on the part closed, the market close and no better.
        assertEq(h.bucketCollateral(winner), 10 * SCALE + closed * 46, "winner credited PnL at the mark");
        assertEq(h.bucketSize(winner), 1 * SCALE - closed, "the rest of the winner stays open");
        // Vault: the slice sold $4 above its entry basis, a D -> I transfer.
        assertEq(h.insurance(), closed * 4, "the fund keeps the recovery above the bankruptcy price");
        assertEq(h.vaultCollateral(), 1_000e18 - closed * 4, "deposits ledger paid the vault's gain");
        assertEq(h.pendingSize(), 1 * SCALE - closed, "the rest of the inventory is carried");
        (, uint256 base, uint256 worstFinish,) = h.exposure(104 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the fund can finish the rest inside the band");
    }

    /// @notice Mirror for short inventory: a mark BELOW the bankruptcy price is the fund's
    ///         favorable side, so the batch settles there. Vault short 1 unit at bankruptcy
    ///         $100, marked $96, against a long winner: the $4 a unit gained and the $0.80 of
    ///         finish cost at the $100.80 band edge put 1/6 of the unit on the release line.
    function test_settlement_markBelowBankruptcy_shortInventorySettlesAtMark() public {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, false);
        // Long winner, 1 unit entered at $50/u, $10 collateral.
        h.setBucket(winner, true, 1 * SCALE, 50 * SCALE, 10 * SCALE);
        h.setOI(1 * SCALE, 0, 50 * SCALE, 0);
        h.setVaultInsurance(0);
        uint256 closed = Math.mulDiv(0.800001e18, SCALE, 4.8e18, Math.Rounding.Ceil);

        BazaarTypes.AdlParams memory p = _paramsAtMark(100 * SCALE, 96 * SCALE, 15);
        p.adlLongs = true;
        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), p);

        assertEq(r.settlementPrice, 96 * SCALE, "settlement = the mark, not the bankruptcy price");
        assertEq(r.totalLiqSize, closed, "1/6 of the unit");
        // Winner: (96 - 50) on the part closed.
        assertEq(h.bucketCollateral(winner), 10 * SCALE + closed * 46, "winner credited PnL at the mark");
        assertEq(h.insurance(), closed * 4, "the fund keeps the recovery below the bankruptcy price");
        assertEq(h.vaultCollateral(), 1_000e18 - closed * 4, "deposits ledger paid the vault's gain");
        assertEq(h.pendingSize(), 1 * SCALE - closed, "the rest of the inventory is carried");
        (, uint256 base, uint256 worstFinish,) = h.exposure(96 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the fund can finish the rest inside the band");
    }

    // ---------------- negative settlement skip ----------------

    /// @notice A winner profitable at the snapshot but negative at the settlement (bankruptcy)
    ///         price is skipped, not force-closed into a realized loss.
    function test_settlement_negativePnlWinnerSkipped() public {
        // Settlement = 200 (bankruptcy) while snapshot = 150.
        h.setPendingLiq(1 * SCALE, 200 * SCALE, true);
        h.setOI(0, 1 * SCALE, 0, 180 * SCALE);
        // Short entered $180: +30 at snapshot 150 (eligible), -20 at settlement 200 (skip).
        h.setBucket(winner, false, 1 * SCALE, 180 * SCALE, 10 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _params(150 * SCALE, 15));

        assertEq(r.totalLiqSize, 0, "nothing closed at a loss");
        assertEq(h.bucketSize(winner), 1 * SCALE, "winner untouched");
        assertEq(h.bucketCollateral(winner), 10 * SCALE, "collateral untouched");
        assertEq(h.pendingSize(), 1 * SCALE, "vault exposure unresolved");
    }

    // ---------------- input guards ----------------

    function test_guard_emptySubmissionReverts() public {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        address[] memory none = new address[](0);
        vm.expectRevert(AdlLib.AdlLib__EmptySubmission.selector);
        h.execAdl(none, _params(100 * SCALE, 15));
    }

    function test_guard_tooManyWinnersReverts() public {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        address[] memory many = new address[](26);
        vm.expectRevert(abi.encodeWithSelector(AdlLib.AdlLib__TooManyWinners.selector, 26, 25));
        h.execAdl(many, _params(100 * SCALE, 15));
    }

    function test_guard_noPendingLiquidationsReverts() public {
        vm.expectRevert(AdlLib.AdlLib__NoPendingLiquidations.selector);
        h.execAdl(_one(winner), _params(100 * SCALE, 15));
    }

    // ---------------- deferred liquidations: the inventory's own side closes them ----------------

    /// @dev Vault long 1 unit at bankruptcy $100 with nothing seized. `loser` is a short from $80
    ///      on $10 — bankrupt at $90 and $10 past it at the $100 mark — whose netting the vault
    ///      declined. `ally` is the long from $80 on $10 that is `loser`'s natural counterparty,
    ///      $20 in profit at the mark.
    function _deferredShortAgainstLongInventory() internal {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setBucket(loser, false, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        h.setBucket(ally, true, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        h.setOI(1 * SCALE, 1 * SCALE, 80 * SCALE, 80 * SCALE);
        h.pushDeferred(loser);
    }

    /// @notice A deferred account is seized inside the batch and its own counterparties are
    ///         closed against it at its bankruptcy price: the seizure covers the loss exactly,
    ///         so the fund moves only by the executor's reward, and the vault's own inventory is
    ///         untouched — this cohort never needed the other one.
    function test_deferred_closedAgainstItsOwnCohort_fundNeutral() public {
        _deferredShortAgainstLongInventory();

        BazaarTypes.AdlResult memory r = h.execAdlBoth(new address[](0), _one(ally), _params(100 * SCALE, 15));

        assertEq(r.deferredClosedSize, 1 * SCALE, "the whole deferred account closed");
        assertEq(r.totalLiqSize, 0, "nothing closed against the vault's inventory");
        assertEq(h.bucketSize(loser), 0, "deferred account seized");
        assertEq(h.bucketSize(ally), 0, "counterparty closed in full");
        // Settled at the $90 bankruptcy price: (90 - 80) x 1 = $10 on top of $10 collateral.
        assertEq(h.bucketCollateral(ally), 20 * SCALE, "credited at the bankruptcy price, not the mark");
        assertEq(h.pendingSize(), 1 * SCALE, "the vault's inventory is not what this cohort closes");
        assertEq(h.deferredCount(), 0, "list emptied");
        assertEq(h.deficit(), 0, "no bad debt");
        // The $0.05 seizure floor (2 bp of $100 is less) plus 0.1% of the $10 the close averted
        // against the mark: the only movement the fund sees.
        assertEq(h.claimable(address(this)), 0.06e18, "seizure floor + averted-loss share");
        assertEq(h.insurance(), 1_000e18 - 0.06e18, "seized $10 in, $10 vault leg out, reward out");
        assertEq(h.vaultCollateral(), 1_000e18, "ledger: seizure out, vault leg back in");
    }

    /// @notice The same close at ten units, where 2 bp of what it retires is above the floor: the
    ///         ten units valued at the $100 mark pay $0.20, plus 0.1% of the $100 the close at the
    ///         $90 bankruptcy price averted.
    function test_deferred_closedAgainstItsOwnCohort_paysTheRateOnWhatItCloses() public {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setBucket(loser, false, 10 * SCALE, 800 * SCALE, 100 * SCALE); // short 10 from $80, bankrupt at $90
        h.setBucket(ally, true, 10 * SCALE, 800 * SCALE, 100 * SCALE);
        h.setOI(10 * SCALE, 10 * SCALE, 800 * SCALE, 800 * SCALE);
        h.pushDeferred(loser);

        BazaarTypes.AdlResult memory r = h.execAdlBoth(new address[](0), _one(ally), _params(100 * SCALE, 15));

        assertEq(r.deferredClosedSize, 10 * SCALE, "the whole account closed against its cohort");
        assertEq(h.bucketCollateral(ally), 200 * SCALE, "credited (90 - 80) x 10 at the bankruptcy price");
        assertEq(h.claimable(address(this)), 0.2e18 + 0.1e18, "2 bp of the $1,000 closed plus 0.1% of $100 averted");
    }

    /// @notice The deferred cohort ranks at the price the call attests, not at the window's
    ///         snapshot. Two longs on the inventory's side: `ally` from $88 on $5 and `winner`
    ///         from $65 on $20. At the $95 snapshot their scores are 1.4 and 1.5, which puts
    ///         `winner` first; at the $100 mark they are 2.4 and 1.75, which puts `ally` first.
    ///         The batch accepts the mark's order and refuses the snapshot's — the order
    ///         BazaarPairLens.getAdlScore reports for this cohort from the stored price. The
    ///         deferred account is two units, one per long: the scan stops once the cohort
    ///         covers it, so a member it never reaches is never order-checked.
    function test_deferred_cohortRanksAtTheAttestedPrice_notTheSnapshot() public {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setBucket(loser, false, 2 * SCALE, 160 * SCALE, 20 * SCALE); // short 2 from $80, bankrupt at $90
        h.setBucket(ally, true, 1 * SCALE, 88 * SCALE, 5 * SCALE);
        h.setBucket(winner, true, 1 * SCALE, 65 * SCALE, 20 * SCALE);
        h.setOI(2 * SCALE, 2 * SCALE, 153 * SCALE, 160 * SCALE);
        h.pushDeferred(loser);

        address[] memory snapshotOrder = new address[](2);
        snapshotOrder[0] = winner;
        snapshotOrder[1] = ally;
        vm.expectPartialRevert(AdlLib.AdlLib__NotDescendingAdlScoreOrder.selector);
        h.execAdlBoth(new address[](0), snapshotOrder, _paramsAtMark(95 * SCALE, 100 * SCALE, 15));

        address[] memory markOrder = new address[](2);
        markOrder[0] = ally;
        markOrder[1] = winner;
        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(new address[](0), markOrder, _paramsAtMark(95 * SCALE, 100 * SCALE, 15));
        assertEq(r.deferredClosedSize, 2 * SCALE, "the deferred account closed against the mark-ranked cohort");
        assertEq(h.bucketSize(loser), 0, "deferred account seized");
        assertEq(h.bucketSize(ally), 0, "the first-ranked long closed in full");
        assertEq(h.bucketSize(winner), 0, "and the second, which the two-unit account needed");
    }

    /// @notice The deferred cohort ranks on its full collateral: a deposit tagged to the current
    ///         window is not subtracted from an account on the inventory's side. Two longs from
    ///         the same book: `ally` from $88 on $25, of which $20 was deposited during this
    ///         window (epoch 7), and `winner` from $65 on $20 with no tag. At the $100 mark their
    ///         profits are $12 and $35. On full collateral the scores are 0.48 and 1.75, which
    ///         puts `winner` first; with the tag subtracted `ally` would score 12 / 5 = 2.4 and
    ///         stand first, ahead of the more levered account, at a bankruptcy-price close its
    ///         top-up should have spared it. The batch accepts the full-collateral order and
    ///         refuses the tag's, and the deposit still counts in full at settlement.
    function test_deferred_cohortRanksOnFullCollateral_windowDepositNotSubtracted() public {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setBucket(loser, false, 2 * SCALE, 160 * SCALE, 20 * SCALE); // short 2 from $80, bankrupt at $90
        h.setBucket(ally, true, 1 * SCALE, 88 * SCALE, 25 * SCALE);
        h.setBucket(winner, true, 1 * SCALE, 65 * SCALE, 20 * SCALE);
        h.setOI(2 * SCALE, 2 * SCALE, 153 * SCALE, 160 * SCALE);
        h.pushDeferred(loser);
        h.setAdlEpoch(7);
        h.setWindowDeposit(ally, 7, 20 * SCALE); // tagged to the live window

        address[] memory taggedOrder = new address[](2);
        taggedOrder[0] = ally;
        taggedOrder[1] = winner;
        vm.expectPartialRevert(AdlLib.AdlLib__NotDescendingAdlScoreOrder.selector);
        h.execAdlBoth(new address[](0), taggedOrder, _paramsAtMark(95 * SCALE, 100 * SCALE, 15));

        address[] memory fullCollateralOrder = new address[](2);
        fullCollateralOrder[0] = winner;
        fullCollateralOrder[1] = ally;
        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(new address[](0), fullCollateralOrder, _paramsAtMark(95 * SCALE, 100 * SCALE, 15));
        assertEq(r.deferredClosedSize, 2 * SCALE, "the deferred account closed against the cohort");
        assertEq(h.bucketSize(loser), 0, "deferred account seized");
        assertEq(h.bucketSize(winner), 0, "the more levered long closed first");
        assertEq(h.bucketSize(ally), 0, "the topped-up long closed second, as the two-unit account needed");
        // Settled at the $90 bankruptcy price on the REAL collateral: the top-up counts in full.
        assertEq(h.bucketCollateral(ally), (25 + 2) * SCALE, "$25 plus (90 - 88) x 1");
        assertEq(h.bucketCollateral(winner), (20 + 25) * SCALE, "$20 plus (90 - 65) x 1");
    }

    /// @notice The seizure reward follows the liquidation rule: a deferred account whose position
    ///         is worth less than MIN_ORDER_AMOUNT and has no equity left earns no flat floor, so
    ///         the executor is paid the 2 bp rate on its notional and its share of the averted
    ///         bad debt, nothing more.
    function test_deferred_subMinimumAccountWithNoEquity_paysNoSeizureFloor() public {
        // The same book at 0.04 units: `loser` is a $4 short from $80 on $0.40, bankrupt at $90
        // and $0.40 past it at the $100 mark; `ally` is its counterparty from $80 on $0.40.
        uint256 size = 0.04e18;
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setBucket(loser, false, size, 3.2e18, 0.4e18);
        h.setBucket(ally, true, size, 3.2e18, 0.4e18);
        h.setOI(size, size, 3.2e18, 3.2e18);
        h.pushDeferred(loser);

        BazaarTypes.AdlResult memory r = h.execAdlBoth(new address[](0), _one(ally), _params(100 * SCALE, 15));

        assertEq(r.deferredClosedSize, size, "the whole deferred account closed");
        assertEq(r.totalLiqSize, 0, "nothing closed against the vault's inventory");
        assertEq(h.bucketSize(loser), 0, "deferred account seized");
        // Settled at the $90 bankruptcy price: (90 - 80) x 0.04 = $0.40 on top of $0.40 collateral.
        assertEq(h.bucketCollateral(ally), 0.8e18, "credited at the bankruptcy price");
        assertEq(h.deficit(), 0, "no bad debt");
        // 2 bp of the $4 notional ($0.0008) plus 0.1% of the $0.40 the close averted ($0.0004).
        assertEq(h.claimable(address(this)), 0.0012e18, "no seizure floor for an account with nothing left");
        assertEq(h.insurance(), 1_000e18 - 0.0012e18, "the fund paid only the rate and the averted-loss share");
        assertEq(h.vaultCollateral(), 1_000e18, "ledger: seizure out, vault leg back in");
    }

    /// @notice An account is taken whole or not at all. A cohort covering only half of it leaves
    ///         it listed — the fund has nothing above its reserve here, so the netting the
    ///         deferral avoided is still unaffordable — and a batch that resolves nothing
    ///         reverts. With the other half of the cohort supplied, the same account closes.
    function test_deferred_wholeAccountRule_partialCohortLeavesItListed() public {
        h.setVaultInsurance(0);
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setBucket(loser, false, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        h.setBucket(ally, true, 5 * SCALE / 10, 40 * SCALE, 5 * SCALE);
        h.setOI(5 * SCALE / 10, 1 * SCALE, 40 * SCALE, 80 * SCALE);
        h.pushDeferred(loser);

        vm.expectRevert(AdlLib.AdlLib__NoEligibleWinners.selector);
        h.execAdlBoth(new address[](0), _one(ally), _params(100 * SCALE, 15));
        assertEq(h.deferredCount(), 1, "still listed");
        assertEq(h.bucketSize(loser), 1 * SCALE, "still open");

        h.setBucket(ally2, true, 5 * SCALE / 10, 40 * SCALE, 5 * SCALE);
        h.setOI(1 * SCALE, 1 * SCALE, 80 * SCALE, 80 * SCALE);
        address[] memory cohort = new address[](2);
        cohort[0] = ally;
        cohort[1] = ally2;

        BazaarTypes.AdlResult memory r = h.execAdlBoth(new address[](0), cohort, _params(100 * SCALE, 15));

        assertEq(r.deferredClosedSize, 1 * SCALE, "closed once the cohort covers it");
        assertEq(h.bucketSize(loser), 0, "seized");
        assertEq(h.bucketCollateral(ally), 10 * SCALE, "each half credited (90 - 80) x 0.5");
        assertEq(h.bucketCollateral(ally2), 10 * SCALE, "each half credited (90 - 80) x 0.5");
        assertEq(h.deferredCount(), 0, "list emptied");
        assertEq(h.insurance(), 0, "seized $10 in, $10 vault leg out; an empty fund pays no reward");
    }

    /// @notice A deferred account the cohort cannot cover is netted after all once the netting
    ///         fits: with free capital above what the entry gap costs, the batch seizes it and
    ///         absorbs it into the inventory as liquidate() would have, closing no counterparty
    ///         — and that seizure is what keeps the batch from being empty.
    function test_deferred_nettedOnceAffordable_partialCohort() public {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setBucket(loser, false, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        h.setBucket(ally, true, 5 * SCALE / 10, 40 * SCALE, 5 * SCALE);
        h.setOI(5 * SCALE / 10, 1 * SCALE, 40 * SCALE, 80 * SCALE);
        h.pushDeferred(loser);

        BazaarTypes.AdlResult memory r = h.execAdlBoth(new address[](0), _one(ally), _params(100 * SCALE, 15));

        assertEq(r.deferredClosedSize, 0, "no counterparty closed");
        assertEq(h.bucketSize(loser), 0, "seized");
        assertEq(h.bucketSize(ally), 5 * SCALE / 10, "counterparty untouched");
        assertEq(h.pendingSize(), 0, "netted against the vault's long in full");
        assertEq(h.deferredCount(), 0, "list emptied");
        assertEq(h.deficit(), 0, "the fund could afford the netting");
        // The $20 entry gap ($100 long against $80 short) is the netting's loss, paid by the fund
        // net of the $10 seized, plus the seizure floor.
        assertEq(h.insurance(), 1_000e18 - 10e18 - 0.05e18, "seizure in, entry gap out, floor out");
    }

    /// @notice A cohort profitable at the mark but under water at the deferred account's
    ///         bankruptcy price cannot take it, and the account is left alone rather than seized
    ///         against nobody. The close refuses to realize a loss on such a winner, so counting
    ///         it as coverage would seize the account, close nothing, and drop the estate into the
    ///         netting the deferral was there to avoid — a freeze any caller could trigger by
    ///         choosing the cohort, since executeAdl is permissionless.
    function test_deferred_cohortUnderwaterAtBankruptcyPrice_leavesTheAccountAlone() public {
        // Nothing free, so the netting stays unaffordable and deferral is the only resolution.
        h.setVaultInsurance(0);
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        // Short from $80 on $10: bankrupt at $90, $10 past it at the $100 mark.
        h.setBucket(loser, false, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        // Long from $95 on $10: +$5 at the $100 mark, -$5 at the $90 settlement.
        h.setBucket(ally, true, 1 * SCALE, 95 * SCALE, 10 * SCALE);
        h.setOI(1 * SCALE, 1 * SCALE, 95 * SCALE, 80 * SCALE);
        h.pushDeferred(loser);

        vm.expectRevert(AdlLib.AdlLib__NoEligibleWinners.selector);
        h.execAdlBoth(new address[](0), _one(ally), _params(100 * SCALE, 15));

        assertEq(h.bucketSize(loser), 1 * SCALE, "not seized");
        assertEq(h.bucketSize(ally), 1 * SCALE, "and nothing closed against it");
        assertEq(h.deferredCount(), 1, "still listed");
        assertEq(h.pendingSize(), 1 * SCALE, "the vault's inventory is untouched");
        assertTrue(h.pendingIsLong(), "on its own side: nothing was netted into it");
        assertEq(h.deficit(), 0, "no bad debt");
    }

    /// @notice The deferred pass runs whether or not a cohort was submitted. Only the close
    ///         against counterparties needs one; dropping an account that recovered and netting
    ///         one the fund can now afford read stored state alone, and both have to keep working
    ///         for the caller who is only finishing the inventory — which is the batch that ends
    ///         the window.
    function test_deferred_passRunsWithNoCohort_dropsRecoveredAndNetsAffordable() public {
        // Inventory 1 LONG unit at $100, a fund deep enough to afford the netting.
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setVaultInsurance(1_000e18);
        // Listed and still insolvent: SHORT 1 unit from $80 on $10 at the $100 mark.
        h.setBucket(loser, false, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        // Listed but solvent again: SHORT 1 unit from $100 on $500.
        h.setBucket(ally2, false, 1 * SCALE, 100 * SCALE, 500 * SCALE);
        h.pushDeferred(loser);
        h.pushDeferred(ally2);
        // A winner for the inventory leg, which is the only cohort this caller submits.
        h.setBucket(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        h.setOI(0, 3 * SCALE, 0, 330 * SCALE);

        h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 90 * SCALE, 15));

        assertEq(h.deferredCount(), 0, "both entries resolved without a cohort");
        assertEq(h.bucketSize(ally2), 1 * SCALE, "the recovered account was dropped, not seized");
        assertEq(h.bucketSize(loser), 0, "the insolvent account was seized and netted");
        assertEq(h.deficit(), 0, "the fund could afford the netting");
    }

    /// @notice Once the inventory is gone the deferred accounts still open are seized on the spot
    ///         and become the inventory: there is nothing left to net them against, and the
    ///         window they hold open would otherwise have nothing for the auction to close.
    function test_deferred_seizedOnceTheInventoryIsGone_becomesTheInventory() public {
        // An empty fund can finish nothing inside the band, so the batch closes the whole
        // aggregate; the short winner covers it exactly.
        h.setVaultInsurance(0);
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setBucket(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        h.setBucket(loser, false, 1 * SCALE, 80 * SCALE, 10 * SCALE); // bankrupt at the $90 mark
        h.setOI(0, 2 * SCALE, 0, 230 * SCALE);
        h.pushDeferred(loser);

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 90 * SCALE, 15));

        assertEq(r.totalLiqSize, 1 * SCALE, "the long inventory closed in full");
        assertEq(r.deferredClosedSize, 0, "no cohort was supplied for the deferred account");
        assertEq(h.bucketSize(loser), 0, "seized once the inventory was gone");
        assertEq(h.pendingSize(), 1 * SCALE, "and now the inventory");
        assertFalse(h.pendingIsLong(), "on the deferred account's own side");
        assertEq(h.deferredCount(), 0, "list emptied");
        // The $10 seizure is earmarked against the new inventory, so nothing is free to pay the
        // executor: the reward is skipped, never drawn from the earmark.
        assertEq(h.insurance(), 10e18, "the seizure, untouched by the reward");
        assertEq(h.claimable(address(this)), 0, "no free capital, no reward");
    }

    /// @dev Vault long 1 unit at $10,000 with nothing seized. `loser` is short 3 units from
    ///      $10,000 on $10: under maintenance at the $10,000 mark, and level with the inventory's
    ///      entry, so netting it costs the fund nothing and the first pass takes it.
    function _deferredLargerThanTheInventory() internal {
        h.setPendingLiq(1 * SCALE, 10_000 * SCALE, true);
        h.setBucket(loser, false, 3 * SCALE, 30_000 * SCALE, 10 * SCALE);
        h.setOI(0, 3 * SCALE, 0, 30_000 * SCALE);
        h.pushDeferred(loser);
    }

    /// @notice A deferred account larger than the inventory nets the overlap, and the rest of it
    ///         becomes the inventory. The batch pays 2 bp of the one unit the netting retired,
    ///         $2, not of all three: the two left over are exposure moved onto the fund, paid for
    ///         when they are retired.
    function test_deferred_nettingLargerThanTheInventory_paysTheRateOnTheOverlapOnly() public {
        _deferredLargerThanTheInventory();

        BazaarTypes.AdlResult memory r = h.execAdlBoth(_one(winner), new address[](0), _params(10_000 * SCALE, 15));

        assertEq(r.totalLiqSize, 0, "the inventory moved onto the winners' side, so the leg is skipped");
        assertEq(h.bucketSize(loser), 0, "the deferred account is seized");
        assertEq(h.deferredCount(), 0, "and delisted");
        assertEq(h.pendingSize(), 2 * SCALE, "its two units past the overlap are the inventory now");
        assertFalse(h.pendingIsLong(), "on its side");
        assertEq(h.claimable(address(this)), 2e18, "2 bp of the $10,000 unit netted, not of all three");
    }

    /// @notice Once a netting has moved the inventory onto the deferred side, the next listed
    ///         account sits on the inventory's side: it merges into it rather than netting,
    ///         moves its exposure onto the fund, and earns the $0.05 floor alone.
    function test_deferred_accountMergedAfterAFlip_earnsTheFlatRewardOnly() public {
        _deferredLargerThanTheInventory();
        h.setBucket(loser2, false, 1 * SCALE, 10_000 * SCALE, 10 * SCALE);
        h.setOI(0, 4 * SCALE, 0, 40_000 * SCALE);
        h.pushDeferred(loser2);

        h.execAdlBoth(_one(winner), new address[](0), _params(10_000 * SCALE, 15));

        assertEq(h.bucketSize(loser2), 0, "the second account is seized too");
        assertEq(h.deferredCount(), 0, "the list is empty");
        assertEq(h.pendingSize(), 3 * SCALE, "and merged into the short inventory");
        assertFalse(h.pendingIsLong(), "which stays short");
        assertEq(h.claimable(address(this)), 2e18 + 0.05e18, "the overlap's 2 bp and the merged account's floor");
    }

    // ---------------- a window held by a deferred account no cohort covers ----------------

    /// @dev The vault is long 10 @ $100 against $50 seized (bankrupt at $95), the fund holds $37
    ///      above that earmark, and the mark is $97: the inventory is whole at the mark and the
    ///      fund can finish it at the $92.15 band edge for $28.50, so on its own the inventory
    ///      leg would close nothing. The deferred short, 2 @ $70 against $7, owes $47 beyond its
    ///      collateral. Netting it costs the entry gap, 2 x ($100 - $70) = $60, against the $37
    ///      plus the overlap's $10 of earmark plus its own $7 = $54: unaffordable. No long cohort
    ///      is supplied to cover it, so it holds the window open with nothing else able to move.
    ///      The short winner, 10 @ $110, is in profit at the $100 snapshot and at the mark.
    function _heldWindowSetup() internal {
        h.setPendingLiq(10 * SCALE, 950 * SCALE, true);
        h.setPendingLiqEntryNotional(1000 * SCALE);
        h.setVaultInsurance(87e18);
        h.setBucket(loser, false, 2 * SCALE, 140 * SCALE, 7 * SCALE);
        h.setBucket(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(0, 12 * SCALE, 0, 1240 * SCALE);
        h.pushDeferred(loser);
    }

    /// @dev The size the inventory leg is sized to on that setup. Each unit closed at the $97
    ///      mark hands the fund $2 ($5 of earmark less the $3 lost from $100) and takes $2.85
    ///      off the band-edge finish cost ($100 - $92.15 less the $5 of earmark): $48.50 of
    ///      progress over the 10 units. The fund has to cover the netting's $43 beyond the
    ///      netted slices' own backing, the $0.05 seizure reward it pays, and the finish cost of
    ///      the 8 units the netting leaves, 8 x $2.85 = $22.80, less the $37 it holds: $28.85,
    ///      plus the rounding allowance of one unit of USDC precision.
    function _heldWindowClose(uint256 rewards) internal pure returns (uint256) {
        return Math.mulDiv(28.8e18 + rewards + 1e12, 10 * SCALE, 48.5e18, Math.Rounding.Ceil);
    }

    /// @notice With a deferred account the deferred pass could neither cover nor net, the
    ///         inventory leg closes enough of the whole inventory that the fund can net the
    ///         account afterwards and still carry what remains: the account is absorbed in the
    ///         same batch, the winner keeps the rest of its position, and the release condition
    ///         holds when the batch returns.
    function test_deferred_heldWindow_inventoryLegClosesEnoughToNetIt() public {
        _heldWindowSetup();

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 97 * SCALE, 15));

        uint256 closed = _heldWindowClose(0.05e18);
        assertEq(r.totalLiqSize, closed, "sized to the netting and the release, not to the inventory");
        assertLt(closed, 6 * SCALE, "about 5.95 of the 10 units");
        assertEq(h.bucketSize(winner), 10 * SCALE - closed, "the winner keeps the rest");
        assertEq(h.bucketSize(loser), 0, "the deferred account is seized");
        assertEq(h.deferredCount(), 0, "and delisted");
        assertEq(h.pendingSize(), 10 * SCALE - closed - 2 * SCALE, "the netting took its 2 units off the remainder");
        assertTrue(h.pendingIsLong(), "which kept its side");
        assertEq(h.deficit(), 0, "the fund could afford the netting");
        // $3 lost per unit closed at the mark; the account's $7 in and the netting's $60 out;
        // the seizure reward out. A close at the mark averts nothing and earns nothing itself.
        assertEq(h.insurance(), 87e18 - closed * 3 + 7e18 - 60e18 - 0.05e18, "the fund paid what it could afford");
        assertEq(h.claimable(address(this)), 0.05e18, "the seizure reward only");
        (, uint256 base, uint256 worstFinish,) = h.exposure(97 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the fund can finish the remainder at the band edge: the window releases");
        assertLe(base - worstFinish, 1e12 + 1e3, "with nothing to spare beyond the rounding allowance");
    }

    /// @notice Two listed accounts that together match the one above are sized as a sum, and
    ///         the pass after the close nets them one after the other.
    function test_deferred_heldWindow_sizedForEveryListedAccount() public {
        _heldWindowSetup();
        h.setBucket(loser, false, 1 * SCALE, 70 * SCALE, 35 * SCALE / 10);
        h.setBucket(loser2, false, 1 * SCALE, 70 * SCALE, 35 * SCALE / 10);
        h.pushDeferred(loser2);

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 97 * SCALE, 15));

        // Two seizure rewards instead of one.
        assertEq(r.totalLiqSize, _heldWindowClose(0.1e18), "the same close, plus the second reward");
        assertEq(h.bucketSize(loser), 0, "the first account is netted");
        assertEq(h.bucketSize(loser2), 0, "and the second, from what the first left");
        assertEq(h.deferredCount(), 0, "list emptied");
        assertEq(h.pendingSize(), 10 * SCALE - r.totalLiqSize - 2 * SCALE, "both overlaps off the remainder");
        assertEq(h.deficit(), 0, "both nettings fit");
        (, uint256 base, uint256 worstFinish,) = h.exposure(97 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the window releases");
    }

    /// @notice The setup above at ten times the prices and amounts, where the netting's 2 bp is
    ///         above the floor: the leg is sized for the netting's full-size reward, 2 bp of the
    ///         account's 2 units at the $970 mark, $0.388, and the netting after it pays exactly
    ///         that.
    function test_deferred_heldWindow_sizedForTheNettingsRateAboveTheFloor() public {
        h.setPendingLiq(10 * SCALE, 9_500 * SCALE, true);
        h.setPendingLiqEntryNotional(10_000 * SCALE);
        h.setVaultInsurance(870e18);
        h.setBucket(loser, false, 2 * SCALE, 1_400 * SCALE, 70 * SCALE);
        h.setBucket(winner, false, 10 * SCALE, 11_000 * SCALE, 1_000 * SCALE);
        h.setOI(0, 12 * SCALE, 0, 12_400 * SCALE);
        h.pushDeferred(loser);

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(1_000 * SCALE, 970 * SCALE, 15));

        uint256 reward = 0.388e18;
        // _heldWindowClose's figures times ten: $288 plus the reward and the rounding allowance,
        // over $485 of progress across the 10 units.
        uint256 closed = Math.mulDiv(288e18 + reward + 1e12, 10 * SCALE, 485e18, Math.Rounding.Ceil);
        assertEq(r.totalLiqSize, closed, "sized for the netting's full-size reward");
        assertEq(h.bucketSize(loser), 0, "the deferred account is netted");
        assertEq(h.pendingSize(), 10 * SCALE - closed - 2 * SCALE, "the netting took its 2 units off the remainder");
        assertEq(h.claimable(address(this)), reward, "and pays the reward the leg was sized for");
        (, uint256 base, uint256 worstFinish,) = h.exposure(970 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the window releases");
    }

    /// @notice A winner too small for the sized close is closed whole. The netting fits — the
    ///         close freed more than it needed — but the inventory it leaves is more than the
    ///         fund can finish at the band edge, so the window stays open for the inventory
    ///         leg's next batch, which the ordinary sizing then bounds.
    function test_deferred_heldWindow_shortWinnerNetsItAndLeavesTheRestToTheNextBatch() public {
        _heldWindowSetup();
        h.setBucket(winner, false, 5 * SCALE, 550 * SCALE, 100 * SCALE);
        h.setOI(0, 7 * SCALE, 0, 690 * SCALE);

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 97 * SCALE, 15));

        assertEq(r.totalLiqSize, 5 * SCALE, "the winner's whole position, short of the sized close");
        // After 5 units the fund holds $47 above a $25 earmark on 5 units: the netting's $60
        // against $47 + $10 + $7 = $64 fits.
        assertEq(h.bucketSize(loser), 0, "the deferred account is netted");
        assertEq(h.deferredCount(), 0, "and delisted");
        assertEq(h.pendingSize(), 3 * SCALE, "3 units remain");
        assertEq(h.insurance(), 87e18 - 15e18 + 7e18 - 60e18 - 0.05e18, "the fund paid the netting");
        (, uint256 base, uint256 worstFinish,) = h.exposure(97 * SCALE, 0, 1_000);
        assertEq(worstFinish, 855e16, "finishing 3 units at the band edge costs $8.55");
        assertEq(base, 395e16, "against $3.95 above the earmark");
        assertGt(worstFinish, base, "so the window stays open");
    }

    /// @notice An account whose hole is more than the whole inventory's surplus can fund: no
    ///         close leaves inventory the fund can carry after netting it, so the whole inventory
    ///         goes and the account is seized as the new inventory with nothing to net against.
    function test_deferred_heldWindow_holeBeyondTheInventorysSurplus_retiresTheInventory() public {
        _heldWindowSetup();
        // 4 @ $70 against $14: the netting costs $120 against $37 + $20 + $14, $86 beyond its
        // own backing, and the 10 units' surplus is $20.
        h.setBucket(loser, false, 4 * SCALE, 280 * SCALE, 14 * SCALE);
        h.setOI(0, 14 * SCALE, 0, 1380 * SCALE);

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 97 * SCALE, 15));

        assertEq(r.totalLiqSize, 10 * SCALE, "the whole inventory");
        assertEq(h.bucketSize(loser), 0, "the deferred account is seized");
        assertEq(h.pendingSize(), 4 * SCALE, "and is the inventory now");
        assertFalse(h.pendingIsLong(), "on its own side");
        assertEq(h.deferredCount(), 0, "list emptied");
        // $30 lost closing at the mark, the $14 seized in; the fund paid no netting. The account
        // became the inventory rather than being retired, so it earns the $0.05 floor, not 2 bp
        // of its $388: that is paid to whoever retires it.
        assertEq(h.insurance(), 87e18 - 30e18 + 14e18 - 0.05e18, "the surplus banked against the new inventory");
        assertEq(h.claimable(address(this)), 0.05e18, "the flat seizure reward");
    }

    /// @notice A covering cohort still resolves the account first: the deferred pass closes it
    ///         against its own counterparties at its bankruptcy price, the list is empty when
    ///         the inventory leg sizes its close, and a whole inventory the fund carries is left
    ///         alone.
    function test_deferred_heldWindow_coveringCohortTakesPrecedence_inventoryUntouched() public {
        _heldWindowSetup();
        // Long 2 @ $60 against $20: in profit at the account's $73.50 bankruptcy price.
        h.setBucket(ally, true, 2 * SCALE, 120 * SCALE, 20 * SCALE);
        h.setOI(2 * SCALE, 12 * SCALE, 120 * SCALE, 1240 * SCALE);

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), _one(ally), _paramsAtMark(100 * SCALE, 97 * SCALE, 15));

        assertEq(r.deferredClosedSize, 2 * SCALE, "closed against the cohort");
        assertEq(r.totalLiqSize, 0, "the inventory leg closes nothing");
        assertEq(h.pendingSize(), 10 * SCALE, "the inventory is untouched");
        assertEq(h.bucketSize(winner), 10 * SCALE, "and so is its winner");
        assertEq(h.bucketSize(loser), 0, "the deferred account is seized");
        assertEq(h.bucketSize(ally), 0, "its counterparty took it whole");
        assertEq(h.deferredCount(), 0, "list emptied");
        // Fund neutral: the $7 seized covers the close at $73.50 exactly. The executor earns the
        // seizure reward plus 0.1% of the $47 averted.
        assertEq(h.insurance(), 87e18 - 97e15, "the rewards alone");
        assertEq(h.claimable(address(this)), 97e15, "seizure reward plus the averted cut");
    }

    /// @notice A listed account within its collateral holds no window open, so it neither sizes
    ///         the close nor is taken by the pass after it: the batch closes what the inventory's
    ///         own exposure requires and leaves the account listed and open. Long 10 @ $100
    ///         against $20 seized, marked $90 with $10 above the earmark: $80 of loss beyond the
    ///         earmark at the mark and $125 at the $85.50 band edge, so the ordinary sizing closes
    ///         $115 plus the rounding allowance of the $124.92 each unit repairs at the $98
    ///         bankruptcy settlement. The listed
    ///         short, 2 @ $70 against $41, is $1 inside its collateral and below maintenance;
    ///         netting it costs $60 against $10 + $4 + $41, so the first pass leaves it, and
    ///         after the close its overlap of 0.79 would fit, but the held-only pass does not
    ///         take it.
    function test_deferred_heldWindow_accountWithinItsCollateral_neitherSizesNorIsNetted() public {
        h.setPendingLiq(10 * SCALE, 980 * SCALE, true);
        h.setPendingLiqEntryNotional(1000 * SCALE);
        h.setVaultInsurance(30e18);
        h.setBucket(loser, false, 2 * SCALE, 140 * SCALE, 41 * SCALE);
        h.setBucket(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(0, 12 * SCALE, 0, 1240 * SCALE);
        h.pushDeferred(loser);

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 90 * SCALE, 15));

        uint256 ordinary = Math.mulDiv(115.000001e18, 10 * SCALE, 12_492e16, Math.Rounding.Ceil);
        assertEq(r.totalLiqSize, ordinary, "the ordinary sizing, not the whole inventory");
        assertEq(h.pendingSize(), 10 * SCALE - ordinary, "inventory remains");
        assertEq(h.bucketSize(loser), 2 * SCALE, "the listed account is open");
        assertEq(h.deferredCount(), 1, "and still listed, for the release or a liquidation to take");
        assertEq(h.deficit(), 0, "nothing went wrong");
    }

    /// @notice Negative control: the same inventory, fund and winner with nothing listed. The
    ///         fund carries the inventory, so the batch is sized to zero and closes nothing.
    function test_deferred_heldWindow_nothingListed_wholeInventoryIsLeftAlone() public {
        _heldWindowSetup();
        h.setBucket(loser, false, 0, 0, 0);

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 97 * SCALE, 15));

        assertEq(r.eligibleSize, 10 * SCALE, "the winner is eligible");
        assertEq(r.totalLiqSize, 0, "but nothing is closed");
        assertEq(h.pendingSize(), 10 * SCALE, "the inventory is untouched");
        assertEq(h.deferredCount(), 0, "the flat entry was dropped");
    }

    /// @notice Above water the settlement price is the mark itself, so the sized close settles
    ///         there in one piece and the batch reports a single price.
    function test_deferred_heldWindow_aboveWater_onePriceForTheWholeClose() public {
        _heldWindowSetup();

        vm.recordLogs();
        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 97 * SCALE, 15));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        LoggedClose[] memory closes = _loggedCloses(logs);
        assertEq(closes.length, 1, "one close");
        assertEq(closes[0].size, r.totalLiqSize, "for the whole sized batch");
        assertEq(closes[0].price, 97 * SCALE, "at the mark");
        (uint256 highest, uint256 lowest) = _loggedRange(logs);
        assertEq(highest, 97 * SCALE, "the batch reports the mark");
        assertEq(lowest, 97 * SCALE, "and only the mark");
    }

    // ---------------- a held window against an inventory above water ----------------

    /// @dev The vault is long 10 @ $100, bankrupt at $91: $50 of the estates' $90 of collateral
    ///      was seized in cash and the ledger still owes the other $40. The fund holds $11 above
    ///      the earmark, and the mark is $110: the inventory is above water at the mark and at
    ///      the $104.50 band edge, so on its own it would close nothing. Closing it at its
    ///      bankruptcy price would need the $40 of arrears beyond the earmark, and the netting
    ///      gate holds the survivors' share of that out of reach. Two deferred shorts, each 2 @
    ///      $80 against $5, are $55 past their collateral; netting either loses the $20 a unit
    ///      entry gap, $40, against $11 + $40 − $32 (the 8 survivors' share) + $10 of earmark on
    ///      the overlap + $5 of its own = $34: refused. The short winner, 10 @ $150, is in profit.
    function _aboveWaterHeldSetup() internal {
        h.setPendingLiq(10 * SCALE, 910 * SCALE, true);
        h.setPendingLiqEntryNotional(1_000 * SCALE);
        h.setPendingLiqSeized(50 * SCALE);
        h.setLedgerArrears(40 * SCALE);
        h.setVaultInsurance(61e18);
        h.setBucket(loser, false, 2 * SCALE, 160 * SCALE, 5 * SCALE);
        h.setBucket(loser2, false, 2 * SCALE, 160 * SCALE, 5 * SCALE);
        h.pushDeferred(loser);
        h.pushDeferred(loser2);
        h.setBucket(winner, false, 10 * SCALE, 1_500 * SCALE, 100 * SCALE);
        h.setOI(4 * SCALE, 14 * SCALE, 320 * SCALE, 1_820 * SCALE);
    }

    /// @notice Above water, the inventory the nettings leave is counted at its bankruptcy-priced
    ///         close, $40 over the 10 units, rather than at its zero band-edge finish cost: the
    ///         nettings' $50 beyond their own backing, the two $0.05 rewards, the 6 survivors'
    ///         $24 and the rounding allowance, less the $51 of free capital and arrears, is
    ///         $23.100001, and each unit closed at the $110 mark covers $19 of it — $5 of earmark,
    ///         $10 realized and its $4 share of the survivors' cushion. The leg closes that at the
    ///         mark, the pass after it nets both accounts, and the window releases in one batch.
    function test_deferred_heldWindowAboveWater_closesWhatTheNettingGateNeeds() public {
        _aboveWaterHeldSetup();

        vm.recordLogs();
        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(110 * SCALE, 110 * SCALE, 15));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        uint256 closed = Math.mulDiv(23.100001e18, 10 * SCALE, 190e18, Math.Rounding.Ceil);
        assertEq(r.totalLiqSize, closed, "about 1.22 units, sized on the bankruptcy-priced close");
        assertEq(closes.length, 1, "one close");
        assertEq(closes[0].price, 110 * SCALE, "at the mark: no haircut");
        assertEq(h.bucketSize(loser), 0, "the first account is netted");
        assertEq(h.bucketSize(loser2), 0, "and the second");
        assertEq(h.deferredCount(), 0, "list emptied");
        assertEq(h.pendingSize(), 10 * SCALE - closed - 4 * SCALE, "the nettings took their 4 units");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        _assertSurvivorsBacked(110 * SCALE, 0);
        (, uint256 base, uint256 worstFinish,) = h.exposure(110 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the window releases");
    }

    /// @dev The fund can still close the inventory left at its bankruptcy price without a deficit.
    function _assertSurvivorsBacked(uint256 mark, int256 idx) internal view {
        (uint256 backing, uint256 needed) = h.survivorBacking(mark, idx);
        assertGe(backing, needed, "the inventory left stays backed at its bankruptcy price");
    }

    /// @notice A leg that closes less than it planned leaves the nettings after it gated on the
    ///         whole remainder. On the same book the only winner submitted holds 0.1 units, so
    ///         the leg closes those at the mark and stops short of the 1.22 units it planned.
    ///         Gated on the 5.9 units both nettings would leave, the first would clear and spend
    ///         the arrears the 7.9 units it leaves need once the second is refused; gated on those
    ///         7.9 units, each is refused, and the fund still backs the 9.9 units left at their
    ///         bankruptcy price. A batch whose winner covers the plan then nets both.
    function test_deferred_heldWindowAboveWater_shortLeg_keepsTheWholeRemainderBacked() public {
        _aboveWaterHeldSetup();
        h.setBucket(winner, false, 0.1e18, 15 * SCALE, 1 * SCALE);
        h.setOI(4 * SCALE, 4.1e18, 320 * SCALE, 335 * SCALE);

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(110 * SCALE, 110 * SCALE, 15));

        assertEq(r.totalLiqSize, 0.1e18, "the leg closes the small winner");
        assertEq(h.deferredCount(), 2, "both accounts stay listed");
        assertEq(h.bucketSize(loser), 2 * SCALE, "the first is not netted");
        assertEq(h.bucketSize(loser2), 2 * SCALE, "nor the second");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        _assertSurvivorsBacked(110 * SCALE, 0);

        h.setBucket(winner, false, 10 * SCALE, 1_500 * SCALE, 100 * SCALE);
        h.setOI(4 * SCALE, 14 * SCALE, 320 * SCALE, 1_820 * SCALE);
        h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(110 * SCALE, 110 * SCALE, 15));

        assertEq(h.deferredCount(), 0, "the next batch nets both");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        _assertSurvivorsBacked(110 * SCALE, 0);
    }

    /// @notice The short-inventory mirror of the book above: the vault short 10 @ $100, bankrupt
    ///         at $109, $50 seized and $40 in arrears, marked $90; two deferred longs, each 2 @ $120
    ///         against $5; a long winner from $50. Every figure matches, so the leg closes the same
    ///         size at the mark and the pass after it nets both.
    function test_deferred_heldWindowAboveWater_shortInventory_closesWhatTheNettingGateNeeds() public {
        h.setPendingLiq(10 * SCALE, 1_090 * SCALE, false);
        h.setPendingLiqEntryNotional(1_000 * SCALE);
        h.setPendingLiqSeized(50 * SCALE);
        h.setLedgerArrears(40 * SCALE);
        h.setVaultInsurance(61e18);
        h.setBucket(loser, true, 2 * SCALE, 240 * SCALE, 5 * SCALE);
        h.setBucket(loser2, true, 2 * SCALE, 240 * SCALE, 5 * SCALE);
        h.pushDeferred(loser);
        h.pushDeferred(loser2);
        h.setBucket(winner, true, 10 * SCALE, 500 * SCALE, 100 * SCALE);
        h.setOI(14 * SCALE, 4 * SCALE, 980 * SCALE, 480 * SCALE);
        BazaarTypes.AdlParams memory p = _paramsAtMark(90 * SCALE, 90 * SCALE, 15);
        p.adlLongs = true;

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdlBoth(_one(winner), new address[](0), p);
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        uint256 closed = Math.mulDiv(23.100001e18, 10 * SCALE, 190e18, Math.Rounding.Ceil);
        assertEq(r.totalLiqSize, closed, "the long book's close");
        assertEq(closes.length, 1, "one close");
        assertEq(closes[0].price, 90 * SCALE, "at the mark");
        assertEq(h.deferredCount(), 0, "both accounts netted");
        assertEq(h.pendingSize(), 10 * SCALE - closed - 4 * SCALE, "the nettings took their 4 units");
        assertFalse(h.pendingIsLong(), "the inventory stays short");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        _assertSurvivorsBacked(90 * SCALE, 0);
    }

    /// @dev The vault is long 10 @ $100 against $50 seized, bankrupt at $95, and has paid $3 a unit
    ///      of funding while holding the inventory (the index is at 3, the estates entered at 0):
    ///      closing it at its bankruptcy price needs that $30 beyond the earmark. The fund holds $10
    ///      above the earmark, less than that, and no reserve. Four deferred shorts, each 2 @ $90
    ///      against $15.50 and entered at the live index, are $24.50 past their collateral at the
    ///      $110 mark; netting one loses its $20 entry gap plus the $6 of funding the inventory
    ///      paid on the overlap, $26, half a dollar past its $25.50 of backing. With the whole
    ///      remainder to keep the first pass protects $24 of the $30 and refuses each.
    function _netsWithoutCloseSetup() internal {
        h.setPendingLiq(10 * SCALE, 950 * SCALE, true);
        h.setPendingLiqEntryNotional(1_000 * SCALE);
        h.setVaultInsurance(60e18);
        address[4] memory shorts = [loser, loser2, ally, ally2];
        for (uint256 i = 0; i < 4; i++) {
            h.setBucket(shorts[i], false, 2 * SCALE, 180 * SCALE, 15.5e18);
            h.setBucketFundingIndex(shorts[i], int256(3 * SCALE));
            h.pushDeferred(shorts[i]);
        }
        h.setBucket(winner, false, 10 * SCALE, 1_500 * SCALE, 100 * SCALE);
        h.setOI(8 * SCALE, 18 * SCALE, 800 * SCALE, 2_220 * SCALE);
    }

    /// @dev The batch parameters with the snapshot and the mark both at `mark`, and the live index
    ///      at `idx` since the estates' entry.
    function _paramsAtMarkAndIndex(uint256 mark, int256 idx) internal view returns (BazaarTypes.AdlParams memory p) {
        p = _paramsAtMark(mark, mark, 15);
        p.currentFundingIndex = idx;
        p.adlSnapshotFundingIndex = idx;
    }

    /// @notice When the fund can net every listed account as it stands, the batch closes nothing
    ///         and the pass after the leg nets them: the four nettings' $2 beyond their backing,
    ///         four $0.05 rewards and the 2 survivors' $6 share of the $30 bankruptcy-priced close
    ///         fit the $10 of free capital. The first pass refused each because it protected the
    ///         whole remainder; the pass after the leg protects only what the nettings leave, as
    ///         the plan does.
    function test_deferred_heldWindow_fundNetsThemAsItStands_closesNothing() public {
        _netsWithoutCloseSetup();

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMarkAndIndex(110 * SCALE, int256(3 * SCALE)));

        assertEq(r.totalLiqSize, 0, "no winner is closed");
        assertEq(h.bucketSize(winner), 10 * SCALE, "the winner keeps its position");
        _assertNettedAsItStands();
        assertEq(h.claimable(address(this)), 0.2e18, "four seizure rewards");
    }

    /// @dev The book above once all four accounts are netted: the 2 units left keep $10
    ///      earmarked, and the fund, $60 less each netting's $26 loss net of the $15.50 seized
    ///      with it and less the four rewards, holds $7.80 above that against their $6 share of
    ///      the bankruptcy-priced close.
    function _assertNettedAsItStands() internal view {
        assertEq(h.deferredCount(), 0, "all four accounts are netted");
        assertEq(h.pendingSize(), 2 * SCALE, "their 8 units came off the inventory");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.insurance(), 17.8e18, "the fund after the nettings and the rewards");
        _assertSurvivorsBacked(110 * SCALE, int256(3 * SCALE));
        (, uint256 base, uint256 worstFinish,) = h.exposure(110 * SCALE, int256(3 * SCALE), 1_000);
        assertLe(worstFinish, base, "the window releases");
    }

    /// @notice The nettings need no winner. With the only winner entered at $100, under water at
    ///         the $110 snapshot and so not eligible, the batch still nets all four accounts.
    function test_deferred_heldWindow_fundNetsThemAsItStands_noEligibleWinner() public {
        _netsWithoutCloseSetup();
        h.setBucket(winner, false, 10 * SCALE, 1_000 * SCALE, 100 * SCALE);
        h.setOI(8 * SCALE, 18 * SCALE, 800 * SCALE, 1_720 * SCALE);

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMarkAndIndex(110 * SCALE, int256(3 * SCALE)));

        assertEq(r.eligibleSize, 0, "premise: no winner is eligible");
        assertEq(r.totalLiqSize, 0, "nothing closes");
        assertEq(h.bucketSize(winner), 10 * SCALE, "the winner keeps its position");
        _assertNettedAsItStands();
    }

    /// @notice Nor do they need a winners list: a caller submitting only a deferred cohort, here
    ///         one with no position to close, reaches them too.
    function test_deferred_heldWindow_fundNetsThemAsItStands_deferredCohortOnly() public {
        _netsWithoutCloseSetup();

        BazaarTypes.AdlResult memory r = h.execAdlBoth(
            new address[](0), _one(makeAddr("flat")), _paramsAtMarkAndIndex(110 * SCALE, int256(3 * SCALE))
        );

        assertEq(r.totalLiqSize, 0, "nothing closes");
        assertEq(r.deferredClosedSize, 0, "and nothing against the cohort");
        assertEq(h.bucketSize(winner), 10 * SCALE, "the winner keeps its position");
        _assertNettedAsItStands();
    }

    /// @notice The same book at a $99 mark, where the inventory is under water at the $94.05 band
    ///         edge: finishing it there costs $39.50 beyond the earmark, more than the $15 the fund
    ///         holds free, so the restoring figure alone would close about 4.95 units at the mark.
    ///         The nettings take 8 of the 10 units off the fund, and the four accounts — each 2 @
    ///         $97 against $1.40, $0.60 past its backing — plus their rewards and the 2 survivors'
    ///         $7.90 fit the $15. So the batch nets them and closes nothing: the restoring close
    ///         would have deleveraged winners for inventory the nettings retire.
    function test_deferred_heldWindow_fundNetsThemAsItStands_noRestoringClose() public {
        _netsWithoutCloseSetup();
        h.setVaultInsurance(65e18);
        address[4] memory shorts = [loser, loser2, ally, ally2];
        for (uint256 i = 0; i < 4; i++) {
            h.setBucket(shorts[i], false, 2 * SCALE, 194 * SCALE, 1.4e18);
        }
        (, uint256 base, uint256 worstFinish,) = h.exposure(99 * SCALE, int256(3 * SCALE), 1_000);
        assertGt(worstFinish, base, "premise: the inventory alone needs a restoring close");

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMarkAndIndex(99 * SCALE, int256(3 * SCALE)));

        assertEq(r.totalLiqSize, 0, "no winner is closed");
        assertEq(h.bucketSize(winner), 10 * SCALE, "the winner keeps its position");
        assertEq(h.deferredCount(), 0, "all four accounts are netted");
        assertEq(h.pendingSize(), 2 * SCALE, "their 8 units came off the inventory");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        _assertSurvivorsBacked(99 * SCALE, int256(3 * SCALE));
        (, base, worstFinish,) = h.exposure(99 * SCALE, int256(3 * SCALE), 1_000);
        assertLe(worstFinish, base, "the window releases");
    }

    /// @dev One held-window book with the mark on the fund's side of the bankruptcy price
    ///      (_stageAboveWater).
    struct AboveWaterCase {
        bool vaultShort;
        uint256 arrears;
        uint256 holdingFunding;
        uint256 distance;
        uint256 free;
        uint256 target;
        uint256 trailingGap;
        uint256 size1;
        uint256 gap1;
        uint256 collateral1;
        uint256 size2;
        uint256 gap2;
        uint256 collateral2;
        uint256 winnerSize;
    }

    /// @dev Bounds `c` and stages it, returning the mark and the live funding index. The vault
    ///      holds 10 @ $100 against $50 seized in cash, the deposits ledger owing up to $45 more
    ///      of the estates' collateral, and has paid up to $3 a unit of funding holding it:
    ///      bankrupt at $90.50 to $95 long or $105 to $109.50 short, and marked $96 to $120 long
    ///      or $80 to $104 short, on the fund's side of that. Two accounts opposite the inventory
    ///      entered $1 to $30 below both its $100 entry and the mark when it is long, above both
    ///      when it is short: netting them costs the fund, and against less collateral than they
    ///      have lost at the mark they are past it. The winner, on
    ///      their side, entered at $150 short or $50 long, in profit at every mark staged. The fund
    ///      holds at least the $30 of holding funding above the earmark.
    function _stageAboveWater(AboveWaterCase memory c) internal returns (uint256 mark, int256 idx) {
        uint256 arrears = bound(c.arrears, 0, 45) * SCALE;
        uint256 wSize = bound(c.winnerSize, 10, 30) * SCALE;
        uint256 d1 = bound(c.size1, 1, 4) * SCALE;
        uint256 d2 = bound(c.size2, 1, 4) * SCALE;
        uint256 oi = wSize + d1 + d2;
        uint256 e1;
        uint256 e2;
        idx = int256(bound(c.holdingFunding, 0, 3) * SCALE);
        if (c.vaultShort) {
            idx = -idx;
            mark = 105 - bound(c.distance, 1, 25);
            e1 = (mark > 100 ? mark : 100) + bound(c.gap1, 1, 30);
            e2 = (mark > 100 ? mark : 100) + bound(c.gap2, 1, 30);
            h.setPendingLiq(10 * SCALE, 1_050 * SCALE + arrears, false);
            h.setBucket(loser, true, d1, d1 * e1, bound(c.collateral1, 0, d1 * (e1 - mark) - 1));
            h.setBucket(loser2, true, d2, d2 * e2, bound(c.collateral2, 0, d2 * (e2 - mark) - 1));
            h.setBucket(winner, true, wSize, wSize * 50, 100 * SCALE);
            h.setOI(oi, oi - 10 * SCALE, wSize * 50 + d1 * e1 + d2 * e2, (oi - 10 * SCALE) * 100);
        } else {
            mark = 95 + bound(c.distance, 1, 25);
            e1 = (mark < 100 ? mark : 100) - bound(c.gap1, 1, 30);
            e2 = (mark < 100 ? mark : 100) - bound(c.gap2, 1, 30);
            h.setPendingLiq(10 * SCALE, 950 * SCALE - arrears, true);
            h.setBucket(loser, false, d1, d1 * e1, bound(c.collateral1, 0, d1 * (mark - e1) - 1));
            h.setBucket(loser2, false, d2, d2 * e2, bound(c.collateral2, 0, d2 * (mark - e2) - 1));
            h.setBucket(winner, false, wSize, wSize * 150, 100 * SCALE);
            h.setOI(oi - 10 * SCALE, oi, (oi - 10 * SCALE) * 100, wSize * 150 + d1 * e1 + d2 * e2);
        }
        h.setPendingLiqEntryNotional(1_000 * SCALE);
        h.setPendingLiqSeized(50 * SCALE);
        h.setLedgerArrears(arrears);
        h.setBucketFundingIndex(loser, idx);
        h.setBucketFundingIndex(loser2, idx);
        h.setBucketFundingIndex(winner, idx);
        h.setTargetRatio(bound(c.target, 0, 3_000));
        h.setVaultInsurance(80e18 + bound(c.free, 0, 150) * SCALE);
        h.setTrailingOi(uint128(oi - bound(c.trailingGap, 0, oi - 1)));
        h.pushDeferred(loser);
        h.pushDeferred(loser2);
        mark *= SCALE;
    }

    /// @notice Across both sides, arrears, holding funding, funds, reserves, trailing open
    ///         interest and two listed accounts, with the mark on the fund's side of the
    ///         bankruptcy price and a winner large enough for any plan: one batch resolves every
    ///         listed account and books no deficit, and whatever inventory remains on its side
    ///         meets the window's release condition and can still close at its bankruptcy price —
    ///         free capital and arrears cover that close, less what the executor was paid. Where
    ///         the first pass can afford neither netting, the batch is sized for both, and the
    ///         backing the netting gate reads, free capital above the reserve plus the arrears,
    ///         covers it with the rewards paid. A netting the first pass makes reaches the arrears
    ///         the inventory it leaves needs only once its own seizure is spent, and the gate
    ///         holds what it takes past that to the backing it counts as spendable, so where the
    ///         leg closes nothing that reading, with the rewards paid back, ends no lower than the
    ///         smaller of its value before the batch and the need of the inventory left. A close
    ///         the leg makes pays its earmark ahead of the arrears and nets them by what its loss
    ///         exceeds it, so past a close the reading is bounded only on the sized path.
    function testFuzz_deferred_heldWindowAboveWater_oneBatchResolvesAndKeepsTheRestBacked(AboveWaterCase memory c)
        public
    {
        (uint256 mark, int256 idx) = _stageAboveWater(c);
        _batchAboveWater(c, mark, idx);
    }

    /// @notice A book the gate already reads as short, which the first pass resolves on its own.
    ///         The long inventory needs $75 beyond its earmark to close at its bankruptcy price —
    ///         the $45 the ledger owes of the estates' collateral and $3 a unit of holding funding
    ///         — and the gate reads $45 for it: the arrears, its $30 of free capital sitting below
    ///         the $43.20 reserve. Two shorts of one unit each from $99 against no collateral,
    ///         marked $120, each net at a $4 loss within the $5 earmark on its overlap, so the
    ///         first pass takes both and no plan is needed. The 9 and then 8 units each netting
    ///         leaves need more than the $45 of arrears, so every loss is paid from its earmark:
    ///         the arrears stay at $45, and free capital gains the $1 left of each earmark, $31.90
    ///         after the rewards, under the $36 reserve the nettings lowered. The gate reads $45
    ///         against the $60 the 8 units left need: the book it read $30 short is $15 short,
    ///         the nettings having retired their share of the need without spending any of the
    ///         survivors' backing.
    function test_deferred_heldWindowAboveWater_firstPassNettings_spendNoneOfTheSurvivorsArrears() public {
        AboveWaterCase memory c;
        c.arrears = 45;
        c.holdingFunding = 3;
        c.distance = 25;
        c.target = 3_000;
        c.size1 = 1;
        c.gap1 = 1;
        c.size2 = 1;
        c.gap2 = 1;
        c.winnerSize = 10;
        (uint256 mark, int256 idx) = _stageAboveWater(c);
        (uint256 backingBefore, uint256 neededBefore) = h.survivorBacking(mark, idx);
        assertEq(backingBefore, 45e18, "premise: the gate reads the arrears alone");
        assertEq(neededBefore, 75e18, "against the inventory's $75");

        (bool firstPassNets, uint256 backing, uint256 needed) = _batchAboveWater(c, mark, idx);

        assertTrue(firstPassNets, "premise: the first pass affords the nettings");
        assertEq(h.pendingSize(), 8 * SCALE, "nothing closed beyond the nettings");
        assertEq(h.arrears(), 45e18, "each $4 loss paid from its earmark");
        assertEq(h.freeCapital(), 31.9e18, "the $1 left of each earmark, less the rewards");
        assertEq(backing, 45e18, "the gate's reading after the batch");
        assertEq(needed, 60e18, "the 8 units' bankruptcy-priced close");
    }

    /// @dev Runs one batch against the winner of a book `_stageAboveWater` staged at `mark` and
    ///      `idx`, and checks what every such batch holds: no deficit, every listed account
    ///      resolved, and, for inventory left on its side, the window's release condition and
    ///      free capital plus arrears, with the rewards paid back, covering a close at its
    ///      bankruptcy price — and, where the first pass could afford neither netting, the gate's
    ///      reading of the backing covering it too, or, where the leg closed nothing, that
    ///      reading with the rewards paid back at least the smaller of its value before the
    ///      batch and that close's need.
    /// @param c The staged case, for its side
    /// @param mark The mark the book was staged at
    /// @param idx The live funding index the book was staged at
    /// @return firstPassNets Whether the first pass could afford either netting
    /// @return backing The gate's reading of the backing after the batch, when inventory is left
    ///         on its side
    /// @return needed What a bankruptcy-priced close of that inventory needs beyond its earmark
    function _batchAboveWater(AboveWaterCase memory c, uint256 mark, int256 idx)
        internal
        returns (bool firstPassNets, uint256 backing, uint256 needed)
    {
        firstPassNets = h.nettingAffordable(loser, mark, idx, 10 * SCALE)
            || h.nettingAffordable(loser2, mark, idx, 10 * SCALE);
        (uint256 backingBefore,) = h.survivorBacking(mark, idx);
        BazaarTypes.AdlParams memory p = _paramsAtMarkAndIndex(mark, idx);
        p.adlLongs = c.vaultShort;

        uint256 closed = h.execAdlBoth(_one(winner), new address[](0), p).totalLiqSize;

        assertEq(h.deficit(), 0, "no deficit");
        assertEq(h.deferredCount(), 0, "every listed account is resolved in one batch");
        if (h.pendingSize() != 0 && h.pendingIsLong() != c.vaultShort) {
            (backing, needed) = h.survivorBacking(mark, idx);
            assertGe(
                h.freeCapital() + h.arrears() + h.claimable(address(this)),
                needed,
                "the inventory left can close at its bankruptcy price"
            );
            if (!firstPassNets) {
                assertGe(backing, needed, "sized for both nettings, it stays backed as the gate reads");
            } else if (closed == 0) {
                assertGe(
                    backing + h.claimable(address(this)) + NETTING_ROUNDING,
                    Math.min(backingBefore, needed),
                    "the nettings spent none of the backing the inventory left needs"
                );
            }
            (, uint256 base, uint256 worstFinish,) = h.exposure(mark, idx, 1_000);
            assertLe(worstFinish, base, "the window releases");
        }
    }

    // ---------------- a held window against an inventory under water ----------------

    bytes32 internal constant USER_ADLD_SIG =
        keccak256("UserAdld(bytes32,address,bool,uint256,int256,uint256,uint256,uint256,uint256)");
    bytes32 internal constant ADL_EXECUTED_SIG =
        keccak256("AdlExecuted(bytes32,uint256,bool,address,uint256,uint256,uint256,uint256,uint256,uint256)");

    /// @dev One UserAdld the harness emitted: whose close it was, its size and its price.
    struct LoggedClose {
        address user;
        uint256 size;
        uint256 price;
    }

    /// @dev Every UserAdld in `logs`, in emission order.
    function _loggedCloses(Vm.Log[] memory logs) internal view returns (LoggedClose[] memory out) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(h) && logs[i].topics[0] == USER_ADLD_SIG) n++;
        }
        out = new LoggedClose[](n);
        n = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(h) || logs[i].topics[0] != USER_ADLD_SIG) continue;
            (, uint256 size,,,, uint256 price,) =
                abi.decode(logs[i].data, (bool, uint256, int256, uint256, uint256, uint256, uint256));
            out[n++] = LoggedClose(address(uint160(uint256(logs[i].topics[2]))), size, price);
        }
    }

    /// @dev The price range AdlExecuted reported.
    function _loggedRange(Vm.Log[] memory logs) internal view returns (uint256 highest, uint256 lowest) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(h) || logs[i].topics[0] != ADL_EXECUTED_SIG) continue;
            (, highest, lowest,,,,) =
                abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256, uint256, uint256));
            return (highest, lowest);
        }
        revert("no AdlExecuted");
    }

    /// @dev The vault is long 10 @ $100 against $50 seized (bankrupt at $95) and the mark is $90:
    ///      the inventory is $50 under water at the mark and $95 at the $85.50 band edge, which
    ///      the fund's $120 above the earmark covers, so on its own the inventory leg closes
    ///      nothing. When `listed`, the deferred short, 12 @ $80 against $10, is $110 past its
    ///      collateral and no cohort is supplied for it; its 12 units outnumber the inventory's 10,
    ///      so no netting can leave inventory behind and the whole inventory goes. The short
    ///      winner, 10 @ $110, is in profit at the $100 snapshot and at the mark.
    function _underWaterSetup(bool listed) internal {
        h.setPendingLiq(10 * SCALE, 950 * SCALE, true);
        h.setPendingLiqEntryNotional(1000 * SCALE);
        h.setVaultInsurance(170e18);
        h.setBucket(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        if (listed) {
            h.setBucket(loser, false, 12 * SCALE, 960 * SCALE, 10 * SCALE);
            h.setOI(0, 22 * SCALE, 0, 2060 * SCALE);
            h.pushDeferred(loser);
        } else {
            h.setOI(0, 10 * SCALE, 0, 1100 * SCALE);
        }
    }

    /// @notice Negative control: nothing listed. The fund carries the inventory, so the batch
    ///         closes nothing.
    function test_deferred_heldWindowUnderWater_nothingListed_closesNothing() public {
        _underWaterSetup(false);
        (, uint256 base, uint256 worstFinish,) = h.exposure(90 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the fund can finish the inventory at the band edge");

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 90 * SCALE, 15));

        assertEq(r.totalLiqSize, 0, "nothing is closed");
        assertEq(h.bucketSize(winner), 10 * SCALE, "the winner keeps its position");
    }

    /// @notice The settlement price is the $95 bankruptcy price, but the fund carries the
    ///         inventory, so none of the close is the inventory's own exposure: all 10 units
    ///         close at the $90 mark. The winner realizes its full $200 there, the fund pays the
    ///         $50 between the mark and the bankruptcy price out of its own capital, and the
    ///         deferred short becomes the inventory with nothing to net against.
    function test_deferred_heldWindowUnderWater_retiresTheInventoryAtTheMark() public {
        _underWaterSetup(true);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 90 * SCALE, 15));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(r.settlementPrice, 95 * SCALE, "the inventory's settlement price is its bankruptcy price");
        assertEq(r.totalLiqSize, 10 * SCALE, "the whole inventory");
        assertEq(h.bucketSize(winner), 0, "the winner is closed out");
        assertEq(h.bucketCollateral(winner), 300e18, "at the mark: $100 plus 10 x ($110 - $90), no haircut");
        assertEq(h.deficit(), 0, "the fund could pay the distance");
        assertEq(h.pendingSize(), 12 * SCALE, "the deferred short is the inventory now");
        assertFalse(h.pendingIsLong(), "on its own side");
        assertEq(h.deferredCount(), 0, "list emptied");
        // $100 lost from the $100 entry at the mark, $50 of it the earmark and $50 the fund's
        // own; the deferred account's $10 seized in; its seizure reward out, the $0.05 floor:
        // it became the inventory, so 2 bp of its $1,080 is left to whoever retires it. A close
        // at the mark averts nothing and earns nothing itself.
        assertEq(h.insurance(), 170e18 - 100e18 + 10e18 - 0.05e18, "the fund paid the gap to the mark");
        assertEq(h.claimable(address(this)), 0.05e18, "the flat seizure reward only");

        LoggedClose[] memory closes = _loggedCloses(logs);
        assertEq(closes.length, 1, "one close");
        assertEq(closes[0].price, 90 * SCALE, "settled at the mark");
        (uint256 highest, uint256 lowest) = _loggedRange(logs);
        assertEq(highest, 90 * SCALE, "the batch reports the mark");
        assertEq(lowest, 90 * SCALE, "and only the mark");
    }

    /// @notice The same case with the sides swapped: the vault is short 10 @ $100 against $50
    ///         seized (bankrupt at $105) and the mark is $110. The long winner closes at the mark
    ///         rather than at $105, and the deferred long becomes the inventory.
    function test_deferred_heldWindowUnderWater_shortInventory_retiresItAtTheMark() public {
        h.setPendingLiq(10 * SCALE, 1050 * SCALE, false);
        h.setPendingLiqEntryNotional(1000 * SCALE);
        h.setVaultInsurance(170e18);
        h.setBucket(winner, true, 10 * SCALE, 900 * SCALE, 100 * SCALE);
        h.setBucket(loser, true, 12 * SCALE, 1440 * SCALE, 10 * SCALE);
        h.setOI(22 * SCALE, 0, 2340 * SCALE, 0);
        h.pushDeferred(loser);
        BazaarTypes.AdlParams memory p = _paramsAtMark(100 * SCALE, 110 * SCALE, 15);
        p.adlLongs = true;

        BazaarTypes.AdlResult memory r = h.execAdlBoth(_one(winner), new address[](0), p);

        assertEq(r.settlementPrice, 105 * SCALE, "the inventory's settlement price is its bankruptcy price");
        assertEq(r.totalLiqSize, 10 * SCALE, "the whole inventory");
        assertEq(h.bucketCollateral(winner), 300e18, "at the mark: $100 plus 10 x ($110 - $90), no haircut");
        assertEq(h.deficit(), 0, "the fund could pay the distance");
        assertEq(h.pendingSize(), 12 * SCALE, "the deferred long is the inventory now");
        assertTrue(h.pendingIsLong(), "on its own side");
        // $100 lost at the mark, the $10 seized in, the $0.05 floor out: the account became the
        // inventory, so it earns no rate on its $1,320.
        assertEq(h.insurance(), 170e18 - 100e18 + 10e18 - 0.05e18, "the fund paid the gap to the mark");
    }

    /// @dev The vault is long 10 @ $100 against $90 seized (bankrupt at $91) and the mark is $90,
    ///      with a 20% insurance target: a reserve of 10% of it, $1.80 a unit on the 12 units of
    ///      per-side open interest, $21.60. The fund holds $27.60 above the earmark, $6 above the
    ///      reserve, against a band-edge finish cost of 10 x ($91 - $85.50) = $55, so part of the
    ///      inventory has to close at the bankruptcy price before the fund carries the rest. The
    ///      deferred short, 2 @ $80 against $10, is $10 past its collateral; netting it costs the
    ///      entry gap, 2 x ($100 - $80) = $40, against the fund's $6 plus the overlap's $18 of
    ///      earmark plus its own $10: unaffordable, and no cohort covers it. The short winner,
    ///      10 @ $110, is in profit at the $100 snapshot.
    function _partialSetup() internal {
        h.setPendingLiq(10 * SCALE, 910 * SCALE, true);
        h.setPendingLiqEntryNotional(1000 * SCALE);
        h.setTargetRatio(2_000);
        h.setVaultInsurance(117.6e18);
        h.setBucket(loser, false, 2 * SCALE, 160 * SCALE, 10 * SCALE);
        h.setBucket(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(2 * SCALE, 12 * SCALE, 200 * SCALE, 1260 * SCALE);
        h.pushDeferred(loser);
    }

    /// @dev The two parts of the close on that setup. The fund carries the rest once it has
    ///      closed enough at $91 to cover the $55 finish cost less its $6: each unit there takes
    ///      $5.50 of finish cost off, frees $1.80 of reserve and costs the $0.001 executor cut of
    ///      the $1 it averts, $7.299 in all, for $49 plus the rounding allowance. The netting then
    ///      needs $12 beyond its own backing, its $0.05 seizure reward and the finish cost of the
    ///      8 units it leaves, $44, less the fund's $6, plus the allowance: $50.050001. The units
    ///      at $91 cover $7.299 each of that, and each unit past them closes at the $90 mark,
    ///      where the fund pays $1 past the earmark and nothing is averted: $6.30.
    function _partialSplit() internal pure returns (uint256 atBankruptcy, uint256 atMark) {
        atBankruptcy = Math.mulDiv(49.000001e18, 10 * SCALE, 72.99e18, Math.Rounding.Ceil);
        uint256 covered = Math.mulDiv(54.99e18, atBankruptcy, 10 * SCALE) + Math.mulDiv(18e18, atBankruptcy, 10 * SCALE);
        atMark = Math.mulDiv(50.050001e18 - covered, 10 * SCALE, 63e18, Math.Rounding.Ceil);
    }

    /// @notice Part of the inventory is the fund's to shed and part of the close is only for the
    ///         deferred account: the leg settles the first at the $91 bankruptcy price and the
    ///         rest at the $90 mark, the fund nets the account afterwards, and the window
    ///         releases in the same batch. The one winner straddles both parts, so it is closed
    ///         twice, at each price.
    function test_deferred_heldWindowUnderWater_settlesThePartTheFundCannotCarryAtBankruptcy() public {
        _partialSetup();
        (uint256 atBankruptcy, uint256 atMark) = _partialSplit();
        uint256 total = atBankruptcy + atMark;

        vm.recordLogs();
        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 90 * SCALE, 15));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(r.settlementPrice, 91 * SCALE, "the inventory's settlement price is its bankruptcy price");
        assertEq(r.totalLiqSize, total, "both parts");
        assertLt(total, 7 * SCALE, "about 6.88 of the 10 units");

        LoggedClose[] memory closes = _loggedCloses(logs);
        assertEq(closes.length, 2, "the winner is closed in two parts");
        assertEq(closes[0].size, atBankruptcy, "first the part the fund cannot carry");
        assertEq(closes[0].price, 91 * SCALE, "at the bankruptcy price");
        assertEq(closes[1].size, atMark, "then the part for the deferred account");
        assertEq(closes[1].price, 90 * SCALE, "at the mark");
        (uint256 highest, uint256 lowest) = _loggedRange(logs);
        assertEq(highest, 91 * SCALE, "the batch reports both prices");
        assertEq(lowest, 90 * SCALE, "the mark the lower");

        assertEq(h.bucketSize(winner), 10 * SCALE - total, "the winner keeps the rest");
        // $19 a unit realized at $91 and $20 a unit at $90.
        assertApproxEqAbs(
            h.bucketCollateral(winner),
            100e18 + Math.mulDiv(atBankruptcy, 19e18, SCALE) + Math.mulDiv(atMark, 20e18, SCALE),
            1e3,
            "no haircut on the part closed for the deferred account"
        );
        assertEq(h.bucketSize(loser), 0, "the deferred account is netted");
        assertEq(h.deferredCount(), 0, "and delisted");
        assertEq(h.pendingSize(), 10 * SCALE - total - 2 * SCALE, "the netting took its 2 units off the remainder");
        assertTrue(h.pendingIsLong(), "which kept its side");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        // The executor earns the netting's seizure reward and 0.1% of the $1 a unit the
        // bankruptcy-priced part averted; the part at the mark averts nothing.
        assertEq(h.claimable(address(this)), 0.05e18 + Math.mulDiv(atBankruptcy, 10, 10_000), "rewards");
        // $9 a unit paid at $91, all of it earmark; $10 a unit at $90, $1 of it the fund's own;
        // the account's $10 seized in and the netting's $40 out; the rewards out.
        assertApproxEqAbs(
            h.insurance(),
            117.6e18 - Math.mulDiv(atBankruptcy, 9e18, SCALE) - Math.mulDiv(atMark, 10e18, SCALE) + 10e18 - 40e18
                - h.claimable(address(this)),
            1e3,
            "the fund paid the distance to the mark and the netting"
        );
        (, uint256 base, uint256 worstFinish,) = h.exposure(90 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the fund can finish the remainder at the band edge: the window releases");
    }

    /// @dev The same shape, but the estates took $2 a unit of funding before they were liquidated:
    ///      their entry index sits $2 above the live index, which is also the index they were
    ///      seized at, so the vault has carried no funding since. Long 10 @ $100 against $90
    ///      seized is then bankrupt at $89, and at the $88 mark the fund's $6 above its $21.12
    ///      reserve faces a band-edge finish cost of 10 x ($89 - $83.60) = $54. The deferred
    ///      short, 2 @ $78 against $5.50, is $14.50 past its collateral; netting it costs the entry
    ///      gap less the $4 the two entry indexes differ by on its 2 units, $40, against the fund's
    ///      $6 plus the overlap's $18 of earmark plus its own $5.50: unaffordable.
    function _receivedFundingSetup() internal {
        h.setPendingLiq(10 * SCALE, 890 * SCALE, true);
        h.setPendingLiqEntryNotional(1000 * SCALE);
        h.setPendingLiqSeized(90 * SCALE);
        h.setPendingLiqFundingIndex(int256(2 * SCALE));
        h.setTargetRatio(2_000);
        h.setVaultInsurance(117.12e18);
        h.setBucket(loser, false, 2 * SCALE, 156 * SCALE, 5.5e18);
        h.setBucket(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(2 * SCALE, 12 * SCALE, 200 * SCALE, 1256 * SCALE);
        h.pushDeferred(loser);
    }

    /// @notice The $2 a unit the estates took before liquidation is folded into the $89
    ///         bankruptcy price, and the restoring figure reads it so: 6.70 units at $89 put the
    ///         fund on the release line on their own. The units past them are sized on their own
    ///         settlement figures and close at the $88 mark, which the fund can pay for, so the
    ///         batch nets the deferred account and ends the window in one go.
    function test_deferred_heldWindowUnderWater_receivedFunding_restoringFigureOnTheLine_endsTheWindow() public {
        _receivedFundingSetup();
        // The restoring figure: the $54 band-edge finish cost less the fund's $6, plus the
        // rounding allowance, over the $7.159 a unit a close at $89 frees — $5.40 of finish cost
        // and $1.76 of reserve, less the executor's cut on the $1 averted. The netting close then
        // needs $16.50, the $0.05 reward and the 8 remaining units' $43.20 of finish cost, less
        // the fund's $6, plus the allowance; each unit at $88 takes $5.40 of finish cost off,
        // costs $1 past its earmark and frees $1.76 of reserve.
        uint256 atBankruptcy = Math.mulDiv(48.000001e18, 10 * SCALE, 71.59e18, Math.Rounding.Ceil);
        uint256 covered =
            Math.mulDiv(53.99e18, atBankruptcy, 10 * SCALE) + Math.mulDiv(17.6e18, atBankruptcy, 10 * SCALE);
        uint256 atMark = Math.mulDiv(53.750001e18 - covered, 10 * SCALE, 61.6e18, Math.Rounding.Ceil);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 88 * SCALE, 15));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(r.settlementPrice, 89 * SCALE, "the inventory's settlement price is its bankruptcy price");
        assertEq(closes.length, 2, "two parts");
        assertEq(closes[0].size, atBankruptcy, "the restoring figure at the bankruptcy price");
        assertEq(closes[0].price, 89 * SCALE, "at $89");
        assertEq(closes[1].size, atMark, "the rest at the mark");
        assertEq(closes[1].price, 88 * SCALE, "at $88");
        assertEq(h.bucketSize(loser), 0, "the deferred account is netted");
        assertEq(h.deferredCount(), 0, "and delisted");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        (, uint256 base, uint256 worstFinish,) = h.exposure(88 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the fund can finish the remainder at the band edge: the window releases");
    }

    /// @notice A thin fund that can still pay for the rest at the mark. Long 10 @ $100 against $90
    ///         seized, the estates having taken $3 a unit of funding before liquidation, is
    ///         bankrupt at $88; at the $87 mark the fund holds $3 above the earmark and no reserve.
    ///         The deferred short, 12 @ $80 against $10, outnumbers the inventory, so the batch is
    ///         sized to the whole of it. The restoring figure calls for 9.44 units at $88: the
    ///         $53.50 band-edge finish cost less the fund's $3, over the $5.349 a unit a close
    ///         there frees ($5.35 of finish cost less the cut on the $1 averted). The other 0.56
    ///         cost the fund $1 a unit past their earmark at the mark, which its $3 pays, so they
    ///         close at $87. The inventory is gone, and the deferred short becomes the inventory
    ///         in the same batch.
    function test_deferred_heldWindowUnderWater_receivedFunding_restPaysAtTheMark() public {
        h.setPendingLiq(10 * SCALE, 880 * SCALE, true);
        h.setPendingLiqEntryNotional(1000 * SCALE);
        h.setPendingLiqSeized(90 * SCALE);
        h.setPendingLiqFundingIndex(int256(3 * SCALE));
        h.setVaultInsurance(93e18);
        h.setBucket(loser, false, 12 * SCALE, 960 * SCALE, 10 * SCALE);
        h.setBucket(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(12 * SCALE, 22 * SCALE, 1200 * SCALE, 2060 * SCALE);
        h.pushDeferred(loser);
        uint256 restoring = Math.mulDiv(50.500001e18, 10 * SCALE, 53.49e18, Math.Rounding.Ceil);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 87 * SCALE, 15));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        LoggedClose[] memory closes = _loggedCloses(logs);

        assertEq(closes.length, 2, "two parts");
        assertEq(closes[0].size, restoring, "the restoring figure");
        assertEq(closes[0].price, 88 * SCALE, "at the bankruptcy price");
        assertEq(closes[1].size, 10 * SCALE - restoring, "then the rest");
        assertEq(closes[1].price, 87 * SCALE, "at the mark");
        (uint256 highest, uint256 lowest) = _loggedRange(logs);
        assertEq(highest, 88 * SCALE, "the batch reports both prices");
        assertEq(lowest, 87 * SCALE, "the mark the lower");
        assertEq(r.totalLiqSize, 10 * SCALE, "the whole inventory");
        assertEq(h.pendingSize(), 12 * SCALE, "the deferred short is the inventory now");
        assertFalse(h.pendingIsLong(), "on its own side");
        assertEq(h.deferredCount(), 0, "list emptied");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        // $9 a unit paid at $88, all of it earmark; $10 a unit at $87, $1 of it the fund's own;
        // the account's $10 seized in; its seizure reward, the $0.05 floor since it became the
        // inventory rather than 2 bp of its $1,044, and the 0.1% cut of the $1 a unit the $88
        // part averted out.
        uint256 rewards = 0.05e18 + Math.mulDiv(restoring, 10, 10_000);
        assertEq(h.claimable(address(this)), rewards, "the seizure reward and the averted cut");
        assertApproxEqAbs(
            h.insurance(),
            93e18 - 90e18 - (10 * SCALE - restoring) + 10e18 - rewards,
            1e3,
            "the fund paid the distance to the mark on the rest"
        );
    }

    /// @notice When the nettings take enough inventory off the fund, the size after which the fund
    ///         can net the listed account and carry the rest sits below the restoring figure, and
    ///         the batch closes that size rather than the larger one. Long 10 @ $100 against $90
    ///         seized, the estates having taken $4 a unit of funding before liquidation, is
    ///         bankrupt at $87; at the $83 mark the fund holds $16 above the earmark against a
    ///         $19.92 reserve. The deferred short, 2 @ $76 against $13, is $1 past its collateral,
    ///         and netting it costs $9 beyond its own backing. On its own the inventory needs 8.71
    ///         units closed; with the account netted, 7.97. The batch closes 7.97 at $87 in one
    ///         part, nets the account and releases the window: closing 8.71 would haircut 0.74
    ///         more units for inventory the netting retires.
    function test_deferred_heldWindowUnderWater_nettingFigureBelowTheRestoring_closesTheNettingFigure() public {
        h.setPendingLiq(10 * SCALE, 870 * SCALE, true);
        h.setPendingLiqEntryNotional(1000 * SCALE);
        h.setPendingLiqSeized(90 * SCALE);
        h.setPendingLiqFundingIndex(int256(4 * SCALE));
        h.setTargetRatio(2_000);
        h.setVaultInsurance(106e18);
        h.setBucket(loser, false, 2 * SCALE, 152 * SCALE, 13 * SCALE);
        h.setBucket(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(2 * SCALE, 12 * SCALE, 200 * SCALE, 1252 * SCALE);
        h.pushDeferred(loser);
        // The restoring figure: the $81.50 band-edge finish cost plus the $3.92 the fund sits
        // under its reserve, plus the rounding allowance, over $9.806 a unit ($8.15 of finish
        // cost and $1.66 of reserve, less the cut on $4 averted). The netting close at $87: $9 +
        // $0.05 + the 8 remaining units' $65.20 of finish cost + the $3.92 + the allowance, over
        // the same $9.806.
        uint256 restoring = Math.mulDiv(85.420001e18, 10 * SCALE, 98.06e18, Math.Rounding.Ceil);
        uint256 netting = Math.mulDiv(78.170001e18, 10 * SCALE, 98.06e18, Math.Rounding.Ceil);
        assertLt(netting, restoring, "the netting figure is the smaller");

        vm.recordLogs();
        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 83 * SCALE, 15));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(closes.length, 1, "one part");
        assertEq(closes[0].size, netting, "the netting figure");
        assertEq(closes[0].price, 87 * SCALE, "at the bankruptcy price");
        uint256 settled = netting;
        assertEq(r.totalLiqSize, settled, "7.97 units, not the 8.71 the inventory alone would need");
        assertEq(h.bucketCollateral(winner), 100e18 + Math.mulDiv(settled, 23e18, SCALE), "$23 a unit at $87");
        assertEq(h.bucketSize(loser), 0, "the deferred account is netted");
        assertEq(h.deferredCount(), 0, "and delisted");
        assertEq(h.pendingSize(), 10 * SCALE - settled - 2 * SCALE, "the netting took its 2 units off the remainder");
        assertTrue(h.pendingIsLong(), "which kept its side");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        (, uint256 base, uint256 worstFinish,) = h.exposure(83 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the window releases");
    }

    /// @notice Closes at the mark paid from the earmark and by netting the ledger's arrears rather
    ///         than from free capital. Long 10 @ $100 against $50 seized, bankrupt at $95, with
    ///         $100 of arrears the ledger owes the fund: at the $90 mark the inventory loses $100,
    ///         the earmark covers $50 and the arrears the rest, so the fund carries it although it
    ///         holds $1 against a $39.60 reserve. The deferred short outnumbers the inventory, so
    ///         the whole of it goes, all at the mark: the closes spend the earmark and net $50 of
    ///         the arrears instead of spending free capital, and settled at the bankruptcy price
    ///         they would haircut the winner $50 for nothing.
    function test_deferred_heldWindowUnderWater_markCloseSpendsNoFreeCapital_settlesAtTheMarkBelowTheReserve() public {
        h.setPendingLiq(10 * SCALE, 950 * SCALE, true);
        h.setPendingLiqEntryNotional(1000 * SCALE);
        h.setLedgerArrears(100 * SCALE);
        h.setTargetRatio(2_000);
        h.setVaultInsurance(51e18);
        h.setBucket(loser, false, 12 * SCALE, 960 * SCALE, 10 * SCALE);
        h.setBucket(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(12 * SCALE, 22 * SCALE, 1200 * SCALE, 2060 * SCALE);
        h.pushDeferred(loser);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 90 * SCALE, 15));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(r.totalLiqSize, 10 * SCALE, "the whole inventory");
        assertEq(closes.length, 1, "one close");
        assertEq(closes[0].price, 90 * SCALE, "at the mark");
        assertEq(h.bucketCollateral(winner), 300e18, "$20 a unit, no haircut");
        assertEq(h.arrears(), 50e18, "the earmark paid $50 of the close, the arrears the other $50");
        assertEq(h.pendingSize(), 12 * SCALE, "the deferred short is the inventory now");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        // The close spent only the $50 earmark; the account's $10 seized in, its $0.05 seizure
        // reward out: it became the inventory, so it earns no rate.
        assertEq(h.insurance(), 1e18 + 10e18 - 0.05e18, "free capital untouched by the close");
    }

    /// @notice A winner at a loss at the bankruptcy price is skipped there, so the settlement part
    ///         of the batch closes nothing and the fund still cannot carry the inventory. The
    ///         batch then leaves the mark part alone, though the fund could pay for it: the
    ///         netting it was sized for needs the settlement part first, so closing it would spend
    ///         the fund's capital on a batch that cannot end the window. Same setup, but the only
    ///         winner is short 10 @ $90.50 — in profit at the $90 snapshot and mark, at a loss at
    ///         the $91 bankruptcy price.
    function test_deferred_heldWindowUnderWater_settlementPartFallsShort_noMarkCloses() public {
        _partialSetup();
        h.setBucket(winner, false, 10 * SCALE, 905 * SCALE, 100 * SCALE);
        h.setOI(2 * SCALE, 12 * SCALE, 200 * SCALE, 1065 * SCALE);
        uint256 insuranceBefore = h.insurance();

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(90 * SCALE, 90 * SCALE, 15));

        assertEq(r.eligibleSize, 10 * SCALE, "the winner is eligible");
        assertEq(r.totalLiqSize, 0, "but nothing is closed");
        assertEq(h.bucketSize(winner), 10 * SCALE, "the winner keeps its position");
        assertEq(h.pendingSize(), 10 * SCALE, "the inventory is untouched");
        assertEq(h.deferredCount(), 1, "the deferred account is still listed");
        assertEq(h.insurance(), insuranceBefore, "the fund spent nothing");
        assertEq(h.deficit(), 0, "nothing went unpaid");
    }

    /// @dev The fuzzed state: the side the vault holds, how far the mark sits past the bankruptcy
    ///      price, the fund's capital above the earmark, the insurance target, how far live open
    ///      interest sits above its trailing reading, and a deferred account and a winner of any
    ///      size.
    struct UnderWaterCase {
        bool vaultShort;
        uint256 distance;
        uint256 free;
        uint256 target;
        uint256 trailingGap;
        uint256 deferredSize;
        uint256 deferredGap;
        uint256 deferredCollateral;
        uint256 winnerSize;
    }

    /// @dev Bounds `c` and stages it, returning the mark and the bankruptcy price. The vault holds
    ///      10 @ $100 against $50 seized: bankrupt at $95 long or $105 short, and under water at a
    ///      mark $1 to $15 past that. The deferred account sits opposite the inventory, entered
    ///      $1 to $20 past the mark against less collateral than it has lost there; the winner,
    ///      on the same side, entered $10 on the profitable side of the $100 snapshot.
    function _stageUnderWater(UnderWaterCase memory c) internal returns (uint256 mark, uint256 bankruptcy) {
        uint256 distance = bound(c.distance, 1, 15);
        uint256 dSize = bound(c.deferredSize, 1, 15) * SCALE;
        uint256 dGap = bound(c.deferredGap, 1, 20);
        uint256 wSize = bound(c.winnerSize, 10, 30) * SCALE;
        uint256 dEntry;
        if (c.vaultShort) {
            bankruptcy = 105;
            mark = bankruptcy + distance;
            dEntry = mark + dGap;
            h.setPendingLiq(10 * SCALE, 1050 * SCALE, false);
            h.setBucket(loser, true, dSize, dSize * dEntry, bound(c.deferredCollateral, 0, dSize * dGap - 1));
            h.setBucket(winner, true, wSize, wSize * 90, 100 * SCALE);
            h.setOI(
                wSize + dSize,
                wSize + dSize - 10 * SCALE,
                wSize * 90 + dSize * dEntry,
                (wSize + dSize - 10 * SCALE) * 100
            );
        } else {
            bankruptcy = 95;
            mark = bankruptcy - distance;
            dEntry = mark - dGap;
            h.setPendingLiq(10 * SCALE, 950 * SCALE, true);
            h.setBucket(loser, false, dSize, dSize * dEntry, bound(c.deferredCollateral, 0, dSize * dGap - 1));
            h.setBucket(winner, false, wSize, wSize * 110, 100 * SCALE);
            h.setOI(
                wSize + dSize - 10 * SCALE,
                wSize + dSize,
                (wSize + dSize - 10 * SCALE) * 100,
                wSize * 110 + dSize * dEntry
            );
        }
        h.setPendingLiqEntryNotional(1000 * SCALE);
        h.setTargetRatio(bound(c.target, 0, 3_000));
        h.setVaultInsurance(50e18 + bound(c.free, 0, 300) * SCALE);
        h.setTrailingOi(uint128(wSize + dSize - bound(c.trailingGap, 0, wSize + dSize - 1)));
        h.pushDeferred(loser);
        mark *= SCALE;
        bankruptcy *= SCALE;
    }

    /// @dev The batch parameters for the staged side, at `mark`.
    function _paramsFor(UnderWaterCase memory c, uint256 mark) internal view returns (BazaarTypes.AdlParams memory p) {
        p = _paramsAtMark(100 * SCALE, mark, 15);
        p.adlLongs = c.vaultShort;
    }

    /// @notice Across both sides, marks past the bankruptcy price, funds, reserves, trailing open
    ///         interest and deferred accounts: the batch never books a deficit, and every close
    ///         settles at the inventory's settlement price or at the mark, the mark-priced ones
    ///         last.
    function testFuzz_deferred_heldWindowUnderWater_noDeficit_marksLast(UnderWaterCase memory c) public {
        (uint256 mark, uint256 bankruptcy) = _stageUnderWater(c);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdlBoth(_one(winner), new address[](0), _paramsFor(c, mark));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(h.deficit(), 0, "no deficit");
        // A netting the first deferred pass can afford may consume the inventory and flip it onto
        // the winner's side, and the inventory leg is then skipped.
        if (r.eligibleSize != 0) {
            assertEq(r.settlementPrice, bankruptcy, "under water, the settlement price is the bankruptcy price");
        }
        bool markReached;
        uint256 closed;
        for (uint256 i = 0; i < closes.length; i++) {
            if (closes[i].user != winner) continue;
            closed += closes[i].size;
            if (closes[i].price == mark) {
                markReached = true;
            } else {
                assertEq(closes[i].price, bankruptcy, "a close settles at the settlement price or the mark");
                assertFalse(markReached, "the mark-priced part comes last");
            }
        }
        assertEq(closed, r.totalLiqSize, "the inventory leg's closes");
    }

    /// @notice Where the fund carries the inventory as the batch begins, the deferred accounts
    ///         alone holding the window open, none of the close is the inventory's own exposure:
    ///         whatever the leg closes settles at the mark, and the winner realizes it there in
    ///         full. A fund topped up to its reserve plus the band-edge finish cost plus up to $10.
    function testFuzz_deferred_heldWindowUnderWater_fundCarriesAtStart_everyCloseAtTheMark(
        UnderWaterCase memory c,
        uint256 extra
    ) public {
        c.vaultShort = false;
        c.trailingGap = 0;
        c.deferredSize = bound(c.deferredSize, 10, 15);
        (uint256 mark,) = _stageUnderWater(c);
        h.setVaultInsurance(50e18);
        (,, uint256 worstFinish, uint256 shortfall) = h.exposure(mark, 0, 1_000);
        h.setVaultInsurance(50e18 + shortfall + worstFinish + bound(extra, 1, 10) * SCALE);
        uint256 collateralBefore = h.bucketCollateral(winner);

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdlBoth(_one(winner), new address[](0), _paramsFor(c, mark));
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(h.deficit(), 0, "no deficit");
        for (uint256 i = 0; i < closes.length; i++) {
            assertEq(closes[i].price, mark, "no close at the bankruptcy price");
        }
        assertEq(
            h.bucketCollateral(winner),
            collateralBefore + Math.mulDiv(r.totalLiqSize, 110 * SCALE - mark, SCALE),
            "the winner realizes the mark in full"
        );
    }

    // ---------------- both legs in one batch ----------------

    /// @dev The size the inventory leg closes on the shared setup below, and the score it ranks its
    ///      winner at. One long unit at $100 against a $10 fund, marked $90: finishing the unit at
    ///      the $85.50 band edge would cost $14.50 against $10 of capital, plus the rounding
    ///      allowance, and each unit closed repairs $14.49 of that. The score is the winner's $50
    ///      of profit AT THE SNAPSHOT over its $10 of collateral; at the live mark the same winner
    ///      would score 6.
    uint256 internal constant INVENTORY_LEG_CLOSE = 310_559_075_224_292_616;
    uint256 internal constant INVENTORY_LEG_SCORE = 5e18;

    function _bothLegsSetup() internal {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setVaultInsurance(10e18);
        // The inventory leg's winner: short, opposite the inventory, in profit at the snapshot.
        h.setBucket(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        // Listed, but solvent again, so the deferred leg has nothing to do but delist it.
        h.setBucket(loser, false, 1 * SCALE, 100 * SCALE, 500 * SCALE);
        h.pushDeferred(loser);
        h.setOI(1 * SCALE, 2 * SCALE, 100 * SCALE, 250 * SCALE);
    }

    /// @notice The inventory leg with no cohort submitted for the deferred leg. That leg still
    ///         runs — only closing an account against counterparties needs a cohort — so it
    ///         delists the account that is solvent again and does nothing else. This is the
    ///         baseline the batch below must reproduce.
    function test_bothLegs_inventoryLegAlone() public {
        _bothLegsSetup();

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 90 * SCALE, 15));

        assertEq(r.eligibleCount, 1, "the short winner is eligible");
        assertEq(r.highestAdlScore, INVENTORY_LEG_SCORE, "ranked at the frozen snapshot");
        assertEq(r.totalLiqSize, INVENTORY_LEG_CLOSE, "the batch cap bounds the close");
        assertEq(h.deferredCount(), 0, "the deferred leg runs without a cohort and delists it");
    }

    /// @notice The same batch with a cohort attached, so the deferred leg runs. It only delists the
    ///         account that is solvent again: it seizes nothing, closes nothing, and leaves the
    ///         inventory and the fund exactly as above. The inventory leg must therefore reach the
    ///         identical outcome, on the identical basis.
    ///
    ///         The two legs rank against different bases — the deferred cohort sits on the
    ///         inventory's own side and ranks at the live price — so neither may reach the other's.
    ///         Both the closed size and the reported score pin that: the size would be zero if the
    ///         side were taken from the deferred leg, and the score would be 6 rather than 5 if the
    ///         ranking price were.
    function test_bothLegs_inventoryLegUnaffectedByAnIdleDeferredLeg() public {
        _bothLegsSetup();
        // Cohort on the inventory's own side, in profit at the live price.
        h.setBucket(ally, true, 1 * SCALE, 50 * SCALE, 10 * SCALE);

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), _one(ally), _paramsAtMark(100 * SCALE, 90 * SCALE, 15));

        assertEq(h.deferredCount(), 0, "the solvent account was delisted");
        assertEq(r.deferredClosedSize, 0, "and nothing was closed against it");
        assertEq(h.bucketSize(ally), 1 * SCALE, "the cohort member is untouched");
        assertEq(r.eligibleCount, 1, "the short winner is still eligible");
        assertEq(r.highestAdlScore, INVENTORY_LEG_SCORE, "still ranked at the frozen snapshot");
        assertEq(r.totalLiqSize, INVENTORY_LEG_CLOSE, "and the inventory leg closes the same size");
    }

    /// @notice A netting that consumes the inventory exactly leaves the pass with nothing to net
    ///         the next listed account against. That account is seized and seeds the aggregate on
    ///         its own side, rather than measuring a netting against an inventory of zero.
    function test_deferred_nettingThatEmptiesTheInventory_seedsFromTheNextAccount() public {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setVaultInsurance(1_000e18); // affords the netting
        // Two listed shorts, each exactly the inventory's size: from $80 on $10, bankrupt at $90.
        h.setBucket(loser, false, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        h.setBucket(loser2, false, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        h.pushDeferred(loser);
        h.pushDeferred(loser2);
        // A cohort member with no profit at the mark is ineligible, so neither account can be
        // closed against it and both fall through to the netting arm.
        h.setBucket(ally, true, 1 * SCALE, 100 * SCALE, 50 * SCALE);
        h.setOI(1 * SCALE, 2 * SCALE, 100 * SCALE, 160 * SCALE);

        h.execAdlBoth(new address[](0), _one(ally), _params(100 * SCALE, 15));

        assertEq(h.deferredCount(), 0, "both accounts resolved");
        assertEq(h.bucketSize(loser), 0, "the first netted against the inventory");
        assertEq(h.bucketSize(loser2), 0, "the second was seized once nothing was left to net");
        assertEq(h.pendingSize(), 1 * SCALE, "and became the inventory itself");
        assertFalse(h.pendingIsLong(), "on its own side");
        assertEq(h.deficit(), 0, "no bad debt");
        // Both seizures in ($20), the $20 entry gap on the netting out, two $0.05 floors out.
        assertEq(h.insurance(), 1_000e18 - 0.1e18, "seizures in, entry gap out, two reward floors out");
    }

    /// @notice The same sequence at $10,000 a unit, where 2 bp is above the floor: the netting
    ///         that empties the inventory earns 2 bp of the unit it retires, $2, and the account
    ///         that seeds the new inventory retires nothing and earns the $0.05 floor alone.
    function test_deferred_nettingThatEmptiesTheInventory_seedEarnsTheFloorAlone() public {
        h.setPendingLiq(1 * SCALE, 10_000 * SCALE, true);
        // Two listed shorts, each the inventory's size and level with its entry, under maintenance
        // on $10: the first nets at no cost to the fund, the second finds nothing left to net.
        h.setBucket(loser, false, 1 * SCALE, 10_000 * SCALE, 10 * SCALE);
        h.setBucket(loser2, false, 1 * SCALE, 10_000 * SCALE, 10 * SCALE);
        h.pushDeferred(loser);
        h.pushDeferred(loser2);
        h.setOI(0, 2 * SCALE, 0, 20_000 * SCALE);

        h.execAdlBoth(_one(winner), new address[](0), _params(10_000 * SCALE, 15));

        assertEq(h.deferredCount(), 0, "both accounts resolved");
        assertEq(h.pendingSize(), 1 * SCALE, "the second account is the inventory");
        assertFalse(h.pendingIsLong(), "on its own side");
        assertEq(h.claimable(address(this)), 2e18 + 0.05e18, "2 bp of the unit netted and the seed's floor");
    }

    /// @notice A netting in the deferred pass that flips the inventory onto the winners' own side
    ///         leaves those winners untouched: the inventory leg runs only against inventory on
    ///         the other side, and the health check after the batch re-targets the window.
    ///         Closing them would remove the closed size from both that side's open interest and
    ///         the inventory, leaving the other side with exposure nothing offsets.
    function test_deferred_flipInsidePass_skipsSameSideInventoryLeg() public {
        h.setVaultInsurance(10e18); // affords the first netting exactly
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setBucket(loser, false, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        h.setBucket(loser2, false, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        h.pushDeferred(loser);
        h.pushDeferred(loser2);
        h.setBucket(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE); // +$50 short at the mark
        h.setBucket(ally, true, 2 * SCALE, 160 * SCALE, 50 * SCALE); // the shorts' counterparty
        // Longs: ally 2 plus the inventory 1; shorts: loser, loser2, winner.
        h.setOI(2 * SCALE, 3 * SCALE, 160 * SCALE, 310 * SCALE);

        h.execAdlBoth(_one(winner), new address[](0), _params(100 * SCALE, 15));

        assertEq(h.deferredCount(), 0, "both listed accounts resolved");
        assertEq(h.pendingSize(), 1 * SCALE, "the second seeded a fresh inventory");
        assertFalse(h.pendingIsLong(), "on the winners' side");
        assertEq(h.bucketSize(winner), 1 * SCALE, "winner not closed against it");
        assertEq(h.bucketCollateral(winner), 10 * SCALE, "and credited nothing");
        assertEq(h.longOI(), 2 * SCALE, "longs: the counterparty");
        assertEq(h.shortOI() + h.pendingSize(), 2 * SCALE, "shorts plus short inventory match");
        assertEq(h.insurance(), 10e18, "the second seizure is earmarked; nothing left to pay");
        assertEq(h.deficit(), 0, "no bad debt");
    }

    /// @notice The same account twice in a cohort is refused up front: equal scores must be
    ///         ordered by ascending address, and a repeat cannot be.
    function test_deferred_duplicateCohortEntry_reverts() public {
        h.setVaultInsurance(0);
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setBucket(loser, false, 1 * SCALE, 80 * SCALE, 10 * SCALE);
        h.setBucket(ally, true, 5 * SCALE / 10, 40 * SCALE, 5 * SCALE);
        h.setOI(5 * SCALE / 10, 1 * SCALE, 40 * SCALE, 80 * SCALE);
        h.pushDeferred(loser);

        address[] memory cohort = new address[](2);
        cohort[0] = ally;
        cohort[1] = ally;
        vm.expectRevert(abi.encodeWithSelector(AdlLib.AdlLib__NotAscendingAddressTie.selector, ally, ally));
        h.execAdlBoth(new address[](0), cohort, _params(100 * SCALE, 15));
        assertEq(h.deferredCount(), 1, "still listed");
        assertEq(h.bucketSize(loser), 1 * SCALE, "still open");
    }

    /// @notice A repeat the scan never reaches — it stops once the listed size is covered — is
    ///         caught at the close: the coverage test counts the account once per entry, the
    ///         loop closes it once, and the remainder is refused rather than netted past the
    ///         affordability gate. `ally` fills the scan but is under water at the settlement
    ///         price, so only the repeated `ally2` reaches the account.
    function test_deferred_repeatPastScanCutoff_revertsInsteadOfNetting() public {
        h.setVaultInsurance(0);
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setBucket(loser, false, 1 * SCALE, 80 * SCALE, 10 * SCALE); // settles at $90
        h.setBucket(ally, true, 1 * SCALE, 95 * SCALE, 5 * SCALE); // +5 at $100, -5 at $90
        h.setBucket(ally2, true, 5 * SCALE / 10, 40 * SCALE, 5 * SCALE); // +5 at $90
        h.setOI(15 * SCALE / 10, 1 * SCALE, 135 * SCALE, 80 * SCALE);
        h.pushDeferred(loser);

        address[] memory cohort = new address[](3);
        cohort[0] = ally;
        cohort[1] = ally2;
        cohort[2] = ally2;
        vm.expectRevert(abi.encodeWithSelector(AdlLib.AdlLib__CohortDidNotCover.selector, 5 * SCALE / 10));
        h.execAdlBoth(new address[](0), cohort, _params(100 * SCALE, 15));
    }

    // ---------------- the netting gate and the survivors' arrears ----------------

    /// @notice The netting gate keeps what the surviving inventory needs to close at its
    ///         bankruptcy price out of a netting's reach. Long 10 @ $100 against $30 of cash and
    ///         $65 of arrears, the vault having paid $2 a unit of funding while holding it, is
    ///         bankrupt at $90.50; closing it there needs $85 beyond its earmark — the $65 the
    ///         ledger never paid and the $20 of funding — $8.50 a unit. The fund holds nothing
    ///         above the earmark. Netting the short, 4 @ $87 against $3, loses $52 against the
    ///         overlap's $12 of earmark and the $3: $37 beyond its own backing.
    function test_nettingGate_keepsTheSurvivorsBankruptcyCloseBacked() public {
        h.setPendingLiq(10 * SCALE, 905 * SCALE, true);
        h.setPendingLiqEntryNotional(1000 * SCALE);
        h.setPendingLiqSeized(30 * SCALE);
        h.setLedgerArrears(65 * SCALE);
        h.setPendingLiqFundingIndex(0);
        h.setVaultInsurance(30e18);
        h.setBucket(loser, false, 4 * SCALE, 348 * SCALE, 3 * SCALE);
        int256 idx = int256(2 * SCALE);

        // The 6 surviving units need $51, so $14 of the $65 is spendable: $29 with the netted
        // slices' own backing, short of the $52.
        assertFalse(
            h.nettingAffordable(loser, 90 * SCALE, idx, 10 * SCALE), "refused with the whole remainder to keep backed"
        );
        // Were the batch sized to net 4 more units after this one, only 2 would survive: $17 to
        // keep, $48 spendable, $63 with the slices' own backing.
        assertTrue(h.nettingAffordable(loser, 90 * SCALE, idx, 2 * SCALE), "affordable with 2 units to keep backed");
        assertTrue(h.nettingAffordable(loser, 90 * SCALE, idx, 0), "and with nothing to keep backed");
    }

    /// @dev Short 10 @ $100 against $142 of cash and $46 of arrears, the estates having received
    ///      $4.75 a unit before liquidation: bankrupt at $123.55, and closing it there needs the
    ///      $46 beyond its earmark, exactly the arrears. Mark $123.56, no free capital. The long
    ///      winner, 10 @ $90, is in profit at both prices. The deferred long, 1 @ $142.56 against
    ///      $3.04, is $20.71 past its collateral at the mark; netting it loses $42.56 against the
    ///      overlap's $14.20 of earmark and the $3.04.
    function _survivorsArrearsSetup() internal {
        h.setPendingLiq(10 * SCALE, 1235.5e18, false);
        h.setPendingLiqEntryNotional(1000 * SCALE);
        h.setPendingLiqSeized(142e18);
        h.setLedgerArrears(46e18);
        h.setPendingLiqFundingIndex(0);
        h.setVaultInsurance(142e18);
        h.setBucket(winner, true, 10 * SCALE, 900 * SCALE, 100 * SCALE);
        h.setBucket(loser, true, 1 * SCALE, 142.56e18, 3.04e18);
        h.setOI(11 * SCALE, 0, 1042.56e18, 0);
        h.pushDeferred(loser);
    }

    /// @notice A netting may not spend the arrears the surviving inventory needs. Refused in the
    ///         first pass, the account is what the leg is sized for, and with no free capital no
    ///         close short of the whole inventory makes it affordable: the whole inventory closes
    ///         at $123.55, paid from its own arrears and earmark with nothing left over, the
    ///         account becomes the new inventory, and nothing goes unpaid. Spent on the netting,
    ///         the arrears would have left the 9 surviving units $20.77 short at their own
    ///         bankruptcy price.
    function test_deferred_nettingCannotSpendTheSurvivorsArrears_noDeficit() public {
        _survivorsArrearsSetup();
        BazaarTypes.AdlParams memory p = _paramsAtIndex(123.56e18, int256(4.75e18));
        p.adlLongs = true;

        vm.recordLogs();
        BazaarTypes.AdlResult memory r = h.execAdlBoth(_one(winner), new address[](0), p);
        LoggedClose[] memory closes = _loggedCloses(vm.getRecordedLogs());

        assertEq(r.settlementPrice, 123.55e18, "the bankruptcy price");
        assertEq(r.totalLiqSize, 10 * SCALE, "the whole inventory, none of it netted");
        uint256 closed;
        for (uint256 i = 0; i < closes.length; i++) {
            assertEq(closes[i].price, 123.55e18, "every close at the bankruptcy price");
            closed += closes[i].size;
        }
        assertEq(closed, 10 * SCALE, "all of it against the winner");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.arrears(), 0, "the close consumed its own arrears");
        assertEq(h.pendingSize(), 1 * SCALE, "the deferred long is the inventory now");
        assertTrue(h.pendingIsLong(), "on its own side");
        assertEq(h.deferredCount(), 0, "list emptied");
        // $188 paid at $123.55: $46 by netting the arrears, $142 the earmark. The account's $3.04
        // seized in is the new inventory's earmark, so nothing is free to pay the executor.
        assertEq(h.claimable(address(this)), 0, "no free capital for a reward");
        assertEq(h.insurance(), 3.04e18, "the fund paid nothing past its backing");
    }

    /// @notice Two listed accounts past their collateral: the leg is sized for both, and the pass
    ///         after it nets both. The inventory of _partialSetup with its deferred short split in
    ///         two, 1 @ $80 against $2 each: netting either loses $20 against the fund's $6 above
    ///         its reserve, the overlap's $9 of earmark and the $2, so the first pass leaves both.
    ///         The close then needs $18 beyond the two slices' own backing, two $0.05 seizure
    ///         rewards and the 8 remaining units' $44 of finish cost, less the $6, plus the
    ///         rounding allowance: $56.100001, where _partialSplit's one account needs $50.050001.
    function test_deferred_twoHeldAccounts_bothNettedAfterTheLeg() public {
        h.setPendingLiq(10 * SCALE, 910 * SCALE, true);
        h.setPendingLiqEntryNotional(1000 * SCALE);
        h.setTargetRatio(2_000);
        h.setVaultInsurance(117.6e18);
        h.setBucket(loser, false, 1 * SCALE, 80 * SCALE, 2 * SCALE);
        h.setBucket(loser2, false, 1 * SCALE, 80 * SCALE, 2 * SCALE);
        h.setBucket(winner, false, 10 * SCALE, 1100 * SCALE, 100 * SCALE);
        h.setOI(2 * SCALE, 12 * SCALE, 200 * SCALE, 1260 * SCALE);
        h.pushDeferred(loser);
        h.pushDeferred(loser2);
        uint256 atBankruptcy = Math.mulDiv(49.000001e18, 10 * SCALE, 72.99e18, Math.Rounding.Ceil);
        uint256 covered = Math.mulDiv(54.99e18, atBankruptcy, 10 * SCALE) + Math.mulDiv(18e18, atBankruptcy, 10 * SCALE);
        uint256 atMark = Math.mulDiv(56.100001e18 - covered, 10 * SCALE, 63e18, Math.Rounding.Ceil);
        uint256 total = atBankruptcy + atMark;

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(100 * SCALE, 90 * SCALE, 15));

        assertEq(r.totalLiqSize, total, "both parts");
        assertEq(h.bucketSize(loser), 0, "the first account is netted");
        assertEq(h.bucketSize(loser2), 0, "and the second");
        assertEq(h.deferredCount(), 0, "list emptied");
        assertEq(h.pendingSize(), 10 * SCALE - total - 2 * SCALE, "the nettings took their 2 units off the remainder");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.claimable(address(this)), 0.1e18 + Math.mulDiv(atBankruptcy, 10, 10_000), "two seizure rewards");
        (, uint256 base, uint256 worstFinish,) = h.exposure(90 * SCALE, 0, 1_000);
        assertLe(worstFinish, base, "the window releases");
    }

    // ---------------- a netting's loss and the arrears the inventory it leaves needs ----------------

    /// @dev The vault is long 10 @ $100, bankrupt at $91: $50 of the estates' $90 of collateral
    ///      was seized in cash and the ledger still owes the other $40, exactly what closing the
    ///      inventory at its bankruptcy price needs beyond its earmark. The fund holds $10 above
    ///      the earmark under a 30% target, whose reserve on the book's 10 units exceeds it at
    ///      every mark staged here, so the netting gate reads the arrears alone. The 10 units of
    ///      shorts are the loser's 2 from `entry` against no collateral and the winner's 8.
    /// @param entry The loser's entry price
    function _nettingBelowTheReserveSetup(uint256 entry) internal {
        h.setPendingLiq(10 * SCALE, 910 * SCALE, true);
        h.setPendingLiqEntryNotional(1_000 * SCALE);
        h.setPendingLiqSeized(50 * SCALE);
        h.setLedgerArrears(40 * SCALE);
        h.setVaultInsurance(60e18);
        h.setTargetRatio(3_000);
        h.setBucket(loser, false, 2 * SCALE, 2 * entry, 0);
        h.setBucket(winner, false, 8 * SCALE, 1_200 * SCALE, 100 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 2 * entry + 1_200 * SCALE);
    }

    /// @notice A netting the gate passes leaves the inventory it does not net backed as the gate
    ///         reads it. The short, marked $95, loses its $15 entry gap netting 2 units: the gate
    ///         passes it on the $8 of arrears beyond the 8 survivors' $32 and the $10 earmark on
    ///         the overlap. The earmark pays the first $10 into the ledger and the arrears the
    ///         other $5, so they end at $35: the survivors' $32 and $3 the netted units were owed.
    ///         Paid net of the arrears first, they would end at $25 with the whole earmark in free
    ///         capital under the reserve, where the gate does not read it, and the survivors
    ///         would read $7 short with the fund holding the same value.
    function test_nettingBelowTheReserve_backedSurvivorsStayBacked() public {
        _nettingBelowTheReserveSetup(92.5e18);
        (uint256 backingBefore, uint256 neededBefore) = h.survivorBacking(95 * SCALE, 0);
        assertEq(backingBefore, 40e18, "premise: the gate reads the arrears alone");
        assertEq(neededBefore, 40e18, "premise: the inventory is backed as the gate reads it");
        assertTrue(h.nettingAffordable(loser, 95 * SCALE, 0, 10 * SCALE), "premise: the gate passes the netting");

        BazaarTypes.LiquidateResult memory r = h.liquidate(loser, 95 * SCALE, 0);

        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(h.pendingSize(), 8 * SCALE, "and netted against 2 of the 10 units");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.arrears(), 35e18, "the earmark paid first; the arrears the $5 beyond it");
        assertEq(h.vaultCollateral(), 1_010e18, "the earmark paid $10 into the ledger");
        assertEq(h.freeCapital(), 9.95e18, "nothing of the earmark freed; the $0.05 reward paid");
        (uint256 backing, uint256 needed) = h.survivorBacking(95 * SCALE, 0);
        assertEq(needed, 32e18, "the 8 units' bankruptcy-priced close");
        assertEq(backing, 35e18, "still backed as the gate reads them");
    }

    /// @notice A netting the gate passes opens no window the inventory did not already call for.
    ///         At a $91.50 mark the inventory is $5 above water counting its earmark and the
    ///         arrears, and the fund holds nothing above its reserve: no window. The short from
    ///         $91.20 loses $17.60, within the $8 of spare arrears and the $10 earmark the gate
    ///         counts. Paid from the earmark first and then $7.60 of the arrears, it leaves the 8
    ///         units $32.40 of them, $4.40 above water. Paid net of the arrears first, they would
    ///         read $5.60 under water, with the earmark sitting below the reserve, and the ADL
    ///         gate would open a window.
    function test_nettingBelowTheReserve_opensNoWindow() public {
        _nettingBelowTheReserveSetup(91.2e18);
        (uint256 lossBefore, uint256 baseBefore,,) = h.exposure(91.5e18, 0, 1_000);
        assertEq(lossBefore, 0, "premise: no loss at the mark");
        assertEq(baseBefore, 0, "premise: nothing above the reserve");

        h.liquidate(loser, 91.5e18, 0);

        assertEq(h.pendingSize(), 8 * SCALE, "netted");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.arrears(), 32.4e18, "the arrears paid only what the earmark did not");
        (uint256 loss, uint256 base,,) = h.exposure(91.5e18, 0, 1_000);
        assertEq(base, 0, "still nothing above the reserve");
        assertEq(loss, 0, "and no loss at the mark: no window");
    }

    /// @notice A netting that leaves no inventory pays in the same order, and the arrears it does
    ///         not reach stay owed: nothing open relies on them, and a later loss nets them or
    ///         finalize collects them. The vault is long 2 @ $100, bankrupt at $91, $10 of the
    ///         estates' $18 seized in cash and $8 owed; the short, 2 @ $92.50 against nothing,
    ///         loses $15 netting the whole inventory. The earmark pays the first $10, the arrears
    ///         the other $5, and $3 of them stay owed.
    function test_nettingThatEmptiesTheInventory_spendsItsSeizureFirst() public {
        h.setPendingLiq(2 * SCALE, 182 * SCALE, true);
        h.setPendingLiqEntryNotional(200 * SCALE);
        h.setPendingLiqSeized(10 * SCALE);
        h.setLedgerArrears(8 * SCALE);
        h.setVaultInsurance(20e18);
        h.setTargetRatio(3_000);
        h.setBucket(loser, false, 2 * SCALE, 185 * SCALE, 0);
        h.setOI(0, 2 * SCALE, 0, 185 * SCALE);

        h.liquidate(loser, 95 * SCALE, 0);

        assertEq(h.pendingSize(), 0, "the whole inventory netted");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.arrears(), 3e18, "$5 of the arrears netted, $3 still owed");
        assertEq(h.vaultCollateral(), 1_010e18, "the earmark paid $10 into the ledger");
        assertEq(h.insurance(), 9.95e18, "the fund's $10, less the $0.05 reward");
    }

    /// @notice A netting larger than the inventory keeps the arrears the account's remainder
    ///         needs once it is the inventory. The vault is long 2 @ $100, bankrupt at $91, $10
    ///         seized in cash and $8 owed, and the fund holds $2 above the earmark under a reserve
    ///         of over $40. The short, 5 @ $90 against $20 and marked $95, is seized from a ledger
    ///         holding $5, so $15 joins the arrears. Netting 2 of its units against the inventory
    ///         loses the $20 entry gap, which the gate passes on the $8 of arrears, the $10
    ///         earmark and the netted $8 of the account's collateral. Its other 3 units become the
    ///         inventory, bankrupt at $94, and closing them there needs the $9 of the account's
    ///         unpaid collateral that rides on them. The loss is paid from the $12 of netted
    ///         seizure first, then $8 of the $23 of arrears, which end at $15: that $9 and the $6
    ///         of unpaid collateral the netted units carried. Paid net of the arrears first, $3
    ///         would be left.
    function test_nettingThatFlipsTheInventory_keepsTheNewInventorysArrears() public {
        h.setPendingLiq(2 * SCALE, 182 * SCALE, true);
        h.setPendingLiqEntryNotional(200 * SCALE);
        h.setPendingLiqSeized(10 * SCALE);
        h.setLedgerArrears(8 * SCALE);
        h.setVaultInsurance(12e18);
        h.setVaultCollateral(5e18);
        h.setTargetRatio(3_000);
        h.setBucket(loser, false, 5 * SCALE, 450 * SCALE, 20 * SCALE);
        h.setOI(13 * SCALE, 15 * SCALE, 1_300 * SCALE, 1_450 * SCALE);
        assertTrue(h.nettingAffordable(loser, 95 * SCALE, 0, 2 * SCALE), "premise: the gate passes the netting");

        h.liquidate(loser, 95 * SCALE, 0);

        assertEq(h.pendingSize(), 3 * SCALE, "the account's remainder is the inventory");
        assertFalse(h.pendingIsLong(), "on its side");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.arrears(), 15e18, "the new inventory's $9 and the netted units' $6 kept");
        (uint256 backing, uint256 needed) = h.survivorBacking(95 * SCALE, 0);
        assertEq(needed, 9e18, "what the new inventory needs to close at its bankruptcy price");
        assertEq(backing, 15e18, "backed as the gate reads it");
    }

    /// @dev One netting book for the fuzz below, every figure in whole dollars or units.
    struct NettingCase {
        bool shortInventory;
        bool vaultReceives;
        uint256 size;
        uint256 bankruptcyGap;
        uint256 cash;
        uint256 orphan;
        uint256 holdingFunding;
        uint256 accountSize;
        uint256 entryGap;
        uint256 accountFunding;
        uint256 lossAtMark;
        uint256 collateral;
        uint256 ledger;
        uint256 free;
        uint256 target;
        uint256 trailingOi;
    }

    /// @dev Bounds and stages `c`. The vault holds 2 to 20 units entered at $100 and bankrupt $1
    ///      to $20 past that, their collateral split between cash seized and arrears owed, up to
    ///      $20 more of arrears an earlier inventory left behind, and up to $3 a unit of funding
    ///      paid or received holding them. The loser holds 1 to 25 units on the other side,
    ///      entered $1 to $25 past the inventory's entry at an index up to $3 a unit either side
    ///      of the live one, and marked $1 to $20 against its entry on less collateral than that
    ///      loss; the ledger it is seized from holds up to $10 more than its collateral, or less.
    ///      The fund holds up to $60 above the earmark under a target of up to 30%, open interest
    ///      balances, and the reserve is sized on live open interest or a trailing reading below it.
    /// @param c The case to bound and stage
    /// @return mark The mark the book is staged at
    /// @return idx The live funding index
    /// @return moved What the netting moves the fund's balance and arrears by: the account's
    ///         collateral plus the netting's realization, a loss or a gain
    function _stageNetting(NettingCase memory c) internal returns (uint256 mark, int256 idx, int256 moved) {
        c.size = bound(c.size, 2, 20);
        c.bankruptcyGap = bound(c.bankruptcyGap, 1, 20);
        c.cash = bound(c.cash, 0, c.size * c.bankruptcyGap);
        c.holdingFunding = bound(c.holdingFunding, 0, 3);
        c.accountSize = bound(c.accountSize, 1, 25);
        c.entryGap = bound(c.entryGap, 1, 25);
        c.lossAtMark = bound(c.lossAtMark, 1, 20);
        c.collateral = bound(c.collateral, 0, c.accountSize * c.lossAtMark - 1);
        // A long inventory pays funding while the index rises, a short one while it falls.
        idx = int256(c.holdingFunding * SCALE);
        if (c.shortInventory != c.vaultReceives) idx = -idx;
        int256 accountIdx = idx + (int256(bound(c.accountFunding, 0, 6)) - 3) * int256(SCALE);
        uint256 entry;
        if (c.shortInventory) {
            entry = 100 + c.entryGap;
            mark = (entry - c.lossAtMark) * SCALE;
            h.setPendingLiq(c.size * SCALE, c.size * (100 + c.bankruptcyGap) * SCALE, false);
            h.setOI(
                (c.accountSize + c.size) * SCALE,
                c.accountSize * SCALE,
                (c.accountSize * entry + c.size * 100) * SCALE,
                c.accountSize * 100 * SCALE
            );
        } else {
            entry = 100 - c.entryGap;
            mark = (entry + c.lossAtMark) * SCALE;
            h.setPendingLiq(c.size * SCALE, c.size * (100 - c.bankruptcyGap) * SCALE, true);
            h.setOI(
                c.accountSize * SCALE,
                (c.accountSize + c.size) * SCALE,
                c.accountSize * 100 * SCALE,
                (c.accountSize * entry + c.size * 100) * SCALE
            );
        }
        h.setPendingLiqEntryNotional(c.size * 100 * SCALE);
        h.setPendingLiqSeized(c.cash * SCALE);
        h.setLedgerArrears((c.size * c.bankruptcyGap - c.cash + bound(c.orphan, 0, 20)) * SCALE);
        h.setBucket(loser, c.shortInventory, c.accountSize * SCALE, c.accountSize * entry * SCALE, c.collateral * SCALE);
        h.setBucketFundingIndex(loser, accountIdx);
        h.setVaultCollateral(bound(c.ledger, 0, c.collateral + 10) * SCALE);
        h.setVaultInsurance((c.cash + bound(c.free, 0, 60)) * SCALE);
        h.setTargetRatio(bound(c.target, 0, 3_000));
        h.setTrailingOi(uint128(bound(c.trailingOi, 0, c.accountSize + c.size) * SCALE));
        // The realization _netOpposingLiquidation books on the netted size: the entry gap, plus
        // the two sides' entry-clock offset, the inventory having entered at index 0.
        uint256 netted = c.size < c.accountSize ? c.size : c.accountSize;
        int256 funding = -accountIdx * int256(netted);
        moved = int256(c.collateral * SCALE) - int256(netted * c.entryGap * SCALE)
            + (c.shortInventory ? -funding : funding);
    }

    /// @dev The seizure the netting of the loser's position against the inventory would release,
    ///      the inventory's earmark and the loser's seized cash, each pro rata on the overlap and
    ///      rounded as _netOpposingLiquidation rounds them, and what the ledger cannot pay of the
    ///      loser's collateral, which the seizure adds to the arrears.
    /// @return seizure The seizure the netting releases
    /// @return unpaid The part of the loser's collateral the seizure adds to the arrears
    function _nettedSeizure() internal view returns (uint256 seizure, uint256 unpaid) {
        uint256 inventory = h.pendingSize();
        uint256 account = h.bucketSize(loser);
        uint256 netted = inventory < account ? inventory : account;
        uint256 collateral = h.bucketCollateral(loser);
        uint256 ledger = h.vaultCollateral();
        uint256 paid = collateral < ledger ? collateral : ledger;
        seizure = Math.mulDiv(h.insurance() - h.freeCapital(), netted, inventory) + Math.mulDiv(paid, netted, account);
        unpaid = collateral - paid;
    }

    /// @notice Across both sides, the earmark's split between cash and arrears, arrears an earlier
    ///         inventory left, funding the vault paid or received holding the inventory, accounts
    ///         with funding of their own, accounts smaller than the inventory, as large and larger,
    ///         ledgers too thin to pay a seizure, and reserves above and below free capital, sized
    ///         on live or trailing open interest: a netting the gate passes books no deficit, moves
    ///         the fund's balance plus arrears by exactly the account's collateral plus the
    ///         netting's realization, conserves cash, nets the arrears by no more than its loss
    ///         exceeds the seizure it releases, and leaves whatever inventory remains reading,
    ///         with the reward paid back, no less than the smaller of the gate's reading before
    ///         and what that inventory needs to close at its bankruptcy price. A netting the gate
    ///         refuses is deferred, and an account its own funding keeps solvent is left alone.
    /// @param c The book, bounded and staged by _stageNetting
    function testFuzz_netting_spendsOnlyWhatTheGateLetsIt(NettingCase memory c) public {
        (uint256 mark, int256 idx, int256 moved) = _stageNetting(c);
        (uint256 backingBefore,) = h.survivorBacking(mark, idx);
        bool affordable = h.nettingAffordable(loser, mark, idx, h.pendingSize());
        uint256 value = h.insurance() + h.arrears();
        uint256 cash = h.insurance() + h.vaultCollateral();
        // The seizure adds the unpaid part of the loser's collateral to the arrears before the
        // netting pays, so the arrears the payment starts from are those plus that.
        (uint256 ownCash, uint256 unpaid) = _nettedSeizure();
        uint256 arrearsBefore = h.arrears() + unpaid;
        int256 realized = moved - int256(h.bucketCollateral(loser));

        BazaarTypes.LiquidateResult memory r = h.liquidate(loser, mark, idx);

        if (r.liquidatedCount == 0) {
            assertTrue(r.deferredCount == 0 || !affordable, "deferred only when the gate refuses");
            return;
        }
        assertTrue(affordable, "seized only when the gate passes");
        if (realized < 0) {
            uint256 excess = uint256(-realized) > ownCash ? uint256(-realized) - ownCash : 0;
            assertGe(
                h.arrears() + NETTING_ROUNDING,
                arrearsBefore > excess ? arrearsBefore - excess : 0,
                "the arrears pay only what the netted seizure does not"
            );
        }
        uint256 paid = h.claimable(address(this));
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(int256(h.insurance() + h.arrears() + paid), int256(value) + moved, "the netting alone moves the fund");
        assertEq(h.insurance() + h.vaultCollateral() + paid, cash, "cash is conserved");
        (uint256 backing, uint256 needed) = h.survivorBacking(mark, idx);
        assertGe(
            backing + paid + NETTING_ROUNDING,
            Math.min(backingBefore, needed),
            "the inventory left keeps its backing as the gate reads it"
        );
    }

    // ---------------- a close's loss and the arrears the inventory it leaves keeps ----------------

    /// @notice An inventory close at the bankruptcy price leaves the units it does not close their
    ///         arrears. The vault is long 10 @ $100, bankrupt at $91: $50 of the estates' $90 seized
    ///         in cash and $40 owed, what closing it at its bankruptcy price needs beyond its
    ///         earmark. The fund holds $10 above the earmark under a reserve of about $27, and the
    ///         $89 mark puts the inventory under water. The batch closes the 2-unit winner at $91, an
    ///         $18 loss: its $10 of earmark and its $8 share of the arrears. The 8 units left keep
    ///         $32, their need and their share alike, and the gate reads them backed. Netted from
    ///         the arrears first, they would keep $22 while the earmark sat in free capital under
    ///         the reserve.
    function test_adlClose_belowTheReserve_inventoryLeftKeepsItsArrears() public {
        h.setPendingLiq(10 * SCALE, 910 * SCALE, true);
        h.setPendingLiqEntryNotional(1_000 * SCALE);
        h.setPendingLiqSeized(50 * SCALE);
        h.setLedgerArrears(40 * SCALE);
        h.setVaultInsurance(60e18);
        h.setTargetRatio(3_000);
        h.setBucket(winner, false, 2 * SCALE, 300 * SCALE, 100 * SCALE);
        h.setOI(0, 10 * SCALE, 0, 1_100 * SCALE);

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(_one(winner), new address[](0), _paramsAtMark(89 * SCALE, 89 * SCALE, 15));

        assertEq(r.settlementPrice, 91 * SCALE, "settled at the bankruptcy price");
        assertEq(r.totalLiqSize, 2 * SCALE, "the winner's 2 units");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.arrears(), 32e18, "the 8 units keep their $32");
        (uint256 backing, uint256 needed) = h.survivorBacking(89 * SCALE, 0);
        assertEq(needed, 32e18, "their bankruptcy-priced close");
        assertEq(backing, 32e18, "backed as the gate reads them");
    }

    /// @notice A deferred account's close against its own cohort spends its own arrears and none
    ///         of the vault's. The vault is long 10 @ $100, bankrupt at $91, $50 seized and $40
    ///         owed. The deferred short, 2 @ $80 on $5, is seized from a ledger holding $3, so $2
    ///         more is owed; bankrupt at $82.50, it is $15 past its collateral at the $90 mark. Its
    ///         cohort, a long from $70, closes it at $82.50, a $5 loss: its $3 of seizure and its own
    ///         $2 of arrears. The arrears end at the vault's $40. Netted from the arrears first, the
    ///         loss would have taken $3 of the vault's while the account's seizure joined free
    ///         capital.
    function test_deferredCohortClose_leavesTheVaultsArrearsAlone() public {
        h.setPendingLiq(10 * SCALE, 910 * SCALE, true);
        h.setPendingLiqEntryNotional(1_000 * SCALE);
        h.setPendingLiqSeized(50 * SCALE);
        h.setLedgerArrears(40 * SCALE);
        h.setVaultInsurance(60e18);
        h.setVaultCollateral(3e18);
        h.setTargetRatio(3_000);
        h.setBucket(loser, false, 2 * SCALE, 160 * SCALE, 5 * SCALE);
        h.setBucket(ally, true, 2 * SCALE, 140 * SCALE, 10 * SCALE);
        h.setOI(2 * SCALE, 12 * SCALE, 140 * SCALE, 1_160 * SCALE);
        h.pushDeferred(loser);

        BazaarTypes.AdlResult memory r =
            h.execAdlBoth(new address[](0), _one(ally), _paramsAtMark(90 * SCALE, 90 * SCALE, 15));

        assertEq(r.deferredClosedSize, 2 * SCALE, "the account closed against its cohort");
        assertEq(h.bucketSize(loser), 0, "seized");
        assertEq(h.bucketCollateral(ally), 35e18, "credited at the account's $82.50 bankruptcy price");
        assertEq(h.pendingSize(), 10 * SCALE, "the vault's inventory untouched");
        assertEq(h.deficit(), 0, "nothing went unpaid");
        assertEq(h.arrears(), 40e18, "the vault's arrears untouched");
    }

    /// @dev One inventory-leg book for the fuzz below, every figure in whole dollars or units.
    struct CloseCase {
        bool shortInventory;
        bool vaultReceives;
        uint256 size;
        uint256 bankruptcyGap;
        uint256 cash;
        uint256 leftover;
        uint256 holdingFunding;
        uint256 markOffset;
        uint256 winnerSize;
        uint256 free;
        uint256 target;
        uint256 trailingOi;
    }

    /// @dev Bounds and stages `c`. The vault holds 2 to 20 units entered at $100 and bankrupt $1 to
    ///      $20 past that, their collateral split between cash seized and arrears owed, up to $20
    ///      more of arrears an earlier inventory left, and up to $3 a unit of funding paid or
    ///      received holding them. The mark sits from $15 past the bankruptcy price, where the
    ///      inventory is under water and closes there, to $10 short of it, where it closes at the
    ///      mark. The winner, 1 unit up to the inventory's size, is in profit at every price
    ///      staged. The fund holds up to $60 above the earmark under a target of up to 30%, and the
    ///      reserve is sized on live open interest or a trailing reading below it.
    /// @param c The case to bound and stage
    /// @return mark The mark the book is staged at
    /// @return idx The live funding index
    function _stageClose(CloseCase memory c) internal returns (uint256 mark, int256 idx) {
        c.size = bound(c.size, 2, 20);
        c.bankruptcyGap = bound(c.bankruptcyGap, 1, 20);
        c.cash = bound(c.cash, 0, c.size * c.bankruptcyGap);
        c.holdingFunding = bound(c.holdingFunding, 0, 3);
        c.winnerSize = bound(c.winnerSize, 1, c.size);
        c.markOffset = bound(c.markOffset, 0, 25);
        // A long inventory pays funding while the index rises, a short one while it falls.
        idx = int256(c.holdingFunding * SCALE);
        if (c.shortInventory != c.vaultReceives) idx = -idx;
        uint256 others = c.size - c.winnerSize;
        if (c.shortInventory) {
            uint256 bk = 100 + c.bankruptcyGap;
            mark = (bk + 15 - c.markOffset) * SCALE;
            h.setPendingLiq(c.size * SCALE, c.size * bk * SCALE, false);
            h.setBucket(winner, true, c.winnerSize * SCALE, c.winnerSize * 50 * SCALE, 100 * SCALE);
            h.setOI(c.size * SCALE, 0, (c.winnerSize * 50 + others * 100) * SCALE, 0);
        } else {
            uint256 bk = 100 - c.bankruptcyGap;
            mark = (bk - 15 + c.markOffset) * SCALE;
            h.setPendingLiq(c.size * SCALE, c.size * bk * SCALE, true);
            h.setBucket(winner, false, c.winnerSize * SCALE, c.winnerSize * 150 * SCALE, 100 * SCALE);
            h.setOI(0, c.size * SCALE, 0, (c.winnerSize * 150 + others * 100) * SCALE);
        }
        h.setPendingLiqEntryNotional(c.size * 100 * SCALE);
        h.setPendingLiqSeized(c.cash * SCALE);
        h.setLedgerArrears((c.size * c.bankruptcyGap - c.cash + bound(c.leftover, 0, 20)) * SCALE);
        h.setBucketFundingIndex(winner, idx);
        h.setVaultInsurance((c.cash + bound(c.free, 0, 60)) * SCALE);
        h.setTargetRatio(bound(c.target, 0, 3_000));
        h.setTrailingOi(uint128(bound(c.trailingOi, 0, c.size) * SCALE));
    }

    /// @notice Across both sides, the earmark's split between cash and arrears, arrears an earlier
    ///         inventory left, funding the vault paid or received, marks either side of the
    ///         bankruptcy price, winners of any size up to the inventory's, and reserves either side
    ///         of free capital: an inventory batch conserves cash and never leaves the arrears
    ///         further short of what the inventory left needs at its bankruptcy price than they were
    ///         of the whole inventory's need. Where they covered that need, the batch books no
    ///         deficit and the inventory left keeps at least its pro-rata share of the arrears, so
    ///         the netting gate still reads it backed and the ADL gate reads it no worse per unit.
    /// @param c The book, bounded and staged by _stageClose
    function testFuzz_adlClose_inventoryLeftKeepsItsArrears(CloseCase memory c) public {
        (uint256 mark, int256 idx) = _stageClose(c);
        (, uint256 needBefore) = h.survivorBacking(mark, idx);
        uint256 arrearsBefore = h.arrears();
        uint256 sizeBefore = h.pendingSize();
        uint256 cash = h.insurance() + h.vaultCollateral();
        BazaarTypes.AdlParams memory p = _paramsAtMarkAndIndex(mark, idx);
        p.adlLongs = c.shortInventory;

        h.execAdlBoth(_one(winner), new address[](0), p);

        assertEq(h.insurance() + h.vaultCollateral() + h.claimable(address(this)), cash, "cash is conserved");
        (, uint256 needAfter) = h.survivorBacking(mark, idx);
        uint256 arrearsAfter = h.arrears();
        uint256 shortBefore = needBefore > arrearsBefore ? needBefore - arrearsBefore : 0;
        uint256 shortAfter = needAfter > arrearsAfter ? needAfter - arrearsAfter : 0;
        assertLe(shortAfter, shortBefore + NETTING_ROUNDING, "the arrears fall no further short of the need");
        if (arrearsBefore >= needBefore) {
            assertEq(h.deficit(), 0, "nothing went unpaid");
            assertGe(
                arrearsAfter + NETTING_ROUNDING,
                Math.mulDiv(arrearsBefore, h.pendingSize(), sizeBefore),
                "the inventory left keeps its share of the arrears"
            );
        }
    }
}
