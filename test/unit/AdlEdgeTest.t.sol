// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {AdlLib} from "../../src/libraries/AdlLib.sol";

/// @dev Copy of the AdlHarness pattern (LiquidationVaultTest) for the untested AdlLib arms.
contract AdlEdgeHarness {
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
            orders, book, positionBuckets, vault, winners, params, adlEpoch, adlDepositEpoch, adlWindowDeposits
        );
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

    function shortSum() external view returns (uint256) {
        return vault.shortWeightedEntrySum;
    }
}

/// @notice AdlLib arms with no prior coverage: the partial-close of an oversized winner (which
///         rewrites a live user's collateral/size/entry), descending-score ordering, the in-auction
///         score threshold, the negative-settlement skip, and the input guards.
contract AdlEdgeTest is Test {
    uint256 constant SCALE = 1e18;
    AdlEdgeHarness h;
    address winner = makeAddr("winner");

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
                imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0, laggedMmrTs: 0
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
    ///         implies. With a 5% target the reserve is $0.80 per unit of open interest here:
    ///         $800 on the 1000-unit book, so the base is $11,200 rather than $12,000, and each
    ///         unit closed repairs $14.79 rather than $13.99 — 189 units instead of 200.
    function test_batchCap_reserveReleasedByTheCloseShortensTheBatch() public {
        _oversizedWinnerOnDeepInventory();
        h.setVaultInsurance(22_000e18); // free capital = 12,000
        h.setTargetRatio(500); // 5% of the $80,000 book → reserve $800

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _paramsAtMark(90 * SCALE, 80 * SCALE, 15));

        assertApproxEqRel(r.totalLiqSize, 189.3171e18, 0.0001e18, "2,800 excess / 14.79 per unit");
        assertLt(r.totalLiqSize, 200 * SCALE, "sizing without the released reserve would close 200");
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

    /// @notice When the carry drains the fund at least as fast as deleveraging repairs it, no size
    ///         restores health and the cap must not bind: the batch runs to its eligible size
    ///         instead of refusing to act. Vault long 100 units marked $10 ABOVE the bankruptcy
    ///         price but owing $20/unit of funding — expected loss $1,000, of which closing a unit
    ///         removes $10 while handing $12 of threshold back.
    function test_batchCap_carryOutrunsTheRepair_doesNotBind() public {
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
                imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0, laggedMmrTs: 0
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
                imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0, laggedMmrTs: 0
            }),
            pairId: bytes32(uint256(0xADE)),
            adlId: 0,
            currentBlock: uint64(block.number)
        });

        h.execAdl(_one(winner), params);

        // Credit = (100 − 88) − 3 = $9 on top of $5 collateral.
        assertEq(h.bucketCollateral(winner), 14 * SCALE, "winner credited price leg less own tab");
        assertEq(h.insurance(), 24e18 - 9e18, "vault leg from entry: -12 price + 3 funding, booked once");
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
        assertEq(h.insurance(), 10e18, "inventory closed at its own basis: insurance untouched");
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
        assertEq(h.insurance(), 10e18, "inventory closed at its own basis: insurance untouched");
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
                imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0, laggedMmrTs: 0
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
                imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0, laggedMmrTs: 0
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
    function test_settlement_markAboveBankruptcy_longInventorySettlesAtMark() public {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        // Short winner, 1 unit entered at $150/u, $10 collateral.
        h.setBucket(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);
        h.setVaultInsurance(0);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _paramsAtMark(100 * SCALE, 104 * SCALE, 15));

        assertEq(r.settlementPrice, 104 * SCALE, "settlement = the mark, not the bankruptcy price");
        assertEq(r.totalLiqSize, 1 * SCALE, "the unit closed");
        // Winner: (150 - 104) x 1 = $46 credited, the market close and no better.
        assertEq(h.bucketCollateral(winner), 56 * SCALE, "winner credited PnL at the mark");
        assertEq(h.bucketSize(winner), 0, "winner closed");
        // Vault: the slice sold $4 above its entry basis, a D -> I transfer.
        assertEq(h.insurance(), 4e18, "the fund keeps the recovery above the bankruptcy price");
        assertEq(h.vaultCollateral(), 1_000e18 - 4e18, "deposits ledger paid the vault's gain");
        assertEq(h.pendingSize(), 0, "vault exposure cleared");
    }

    /// @notice Mirror for short inventory: a mark BELOW the bankruptcy price is the fund's
    ///         favorable side, so the batch settles there. Vault short 1 unit at bankruptcy
    ///         $100, marked $96, against a long winner.
    function test_settlement_markBelowBankruptcy_shortInventorySettlesAtMark() public {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, false);
        // Long winner, 1 unit entered at $50/u, $10 collateral.
        h.setBucket(winner, true, 1 * SCALE, 50 * SCALE, 10 * SCALE);
        h.setOI(1 * SCALE, 0, 50 * SCALE, 0);
        h.setVaultInsurance(0);

        BazaarTypes.AdlParams memory p = _paramsAtMark(100 * SCALE, 96 * SCALE, 15);
        p.adlLongs = true;
        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), p);

        assertEq(r.settlementPrice, 96 * SCALE, "settlement = the mark, not the bankruptcy price");
        assertEq(r.totalLiqSize, 1 * SCALE, "the unit closed");
        // Winner: (96 - 50) x 1 = $46 credited.
        assertEq(h.bucketCollateral(winner), 56 * SCALE, "winner credited PnL at the mark");
        assertEq(h.insurance(), 4e18, "the fund keeps the recovery below the bankruptcy price");
        assertEq(h.vaultCollateral(), 1_000e18 - 4e18, "deposits ledger paid the vault's gain");
        assertEq(h.pendingSize(), 0, "vault exposure cleared");
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
}
