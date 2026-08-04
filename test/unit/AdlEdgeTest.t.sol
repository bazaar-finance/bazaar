// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {AdlLib} from "../../src/libraries/AdlLib.sol";

/// @dev Copy of the AdlHarness pattern (LiquidationVaultTest) for the untested AdlLib arms.
contract AdlEdgeHarness {
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
        vault.pendingLiqEntryNotional = bankruptcyNotional;
        vault.pendingLiqIsLong = isLong;
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
            orders, positionBuckets, vault, winners, params, adlEpoch, adlDepositEpoch, adlWindowDeposits
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
            adlPendingSince: block.timestamp - elapsedMinutes * 1 minutes,
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

    function _one(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    // ---------------- partial close of an oversized winner ----------------

    /// @notice A winner larger than the vault's pending exposure is PARTIALLY closed: pro-rata
    ///         entry reduction, realized PnL credited to collateral, position left open, and
    ///         insurance/collateral aggregates conserved against the bucket delta.
    function test_partialClose_oversizedWinner_proRataAndConserved() public {
        // Vault long 1 unit at bankruptcy $100/u -> settlement price $100.
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        // Short winner, 2 units entered at $150/u, $10 collateral; +$100 PnL at snapshot $100.
        h.setBucket(winner, false, 2 * SCALE, 300 * SCALE, 10 * SCALE);
        h.setOI(0, 2 * SCALE, 0, 300 * SCALE);

        BazaarTypes.AdlResult memory r = h.execAdl(_one(winner), _params(100 * SCALE, 15));

        assertEq(r.settlementPrice, 100 * SCALE, "settlement = bankruptcy notional / size");
        assertEq(r.totalLiqSize, 1 * SCALE, "only the vault's exposure closed");
        assertEq(h.bucketSize(winner), 1 * SCALE, "half the position remains open");
        assertEq(h.bucketEntry(winner), 150 * SCALE, "entry reduced pro-rata");
        // Realized PnL on the closed half: 100/2 = 50, credited on top of raw collateral 10.
        assertEq(h.bucketCollateral(winner), 60 * SCALE, "collateral += realized partial PnL");
        assertEq(h.insurance(), 1_000e18 - 50e18, "insurance funded the credit");
        assertEq(h.vaultCollateral(), 1_000e18 + 50e18, "aggregate collateral mirrors the bucket delta");
        assertEq(h.pendingSize(), 0, "vault exposure cleared");
        assertEq(h.shortOI(), 1 * SCALE, "closed half removed from OI");
        assertEq(h.shortSum(), 150 * SCALE, "closed entry removed from weighted sum");
    }

    // ---------------- funding settles ONCE, through the winner's credit ----------------

    /// @notice ADL funding settlement is entirely internal to the winner's credit: their own tab
    ///         is netted inside totalPnl (receiving less IS insurance collecting), and the
    ///         estates' pre-liquidation funding reaches them via the bankruptcy-derived
    ///         settlement price. Insurance must make exactly ONE entry — the winner's credit.
    ///         A prior version also booked a separate "vault window funding" entry, double-paying
    ///         the same transfer.
    function test_adlClose_fundingSettlesOnceViaWinnerCredit() public {
        // Vault long 1 unit at bankruptcy $100/u; liquidatee's entry funding index 0.
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setPendingLiqFundingIndex(0);
        // Short winner, 1 unit entered at $150/u, $10 collateral, entry funding index 0.
        h.setBucket(winner, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);

        // Index delta +2: shorts are owed $2/unit; the vault's long inventory is the payer.
        BazaarTypes.AdlParams memory params = BazaarTypes.AdlParams({
            adlLongs: false,
            adlSnapshotPrice: 100 * SCALE,
            adlSnapshotFundingIndex: int256(2 * SCALE),
            adlPendingSince: block.timestamp - 15 minutes,
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

        // Winner credit: price PnL (150−100) + own funding receivable (+2) = $52. That +$2 inside
        // the credit IS the vault paying its funding — no second entry may exist.
        assertEq(h.bucketCollateral(winner), 62 * SCALE, "winner paid totalPnl incl. funding");
        assertEq(h.insurance(), 1_000e18 - 52e18, "insurance pays the winner credit ONCE, no separate funding entry");
        assertEq(h.vaultCollateral(), 1_000e18 + 52e18, "deposits ledger mirrors the single I->D transfer");
        assertEq(h.pendingSize(), 0, "vault exposure cleared");
    }

    /// @notice Regression for the double-count: estate accrued funding BEFORE liquidation (owed
    ///         $2, embedded in the bankruptcy price: bk = 100 − 10 − 2 = 88) AND the index moved
    ///         further while the vault held the inventory. Ledger walk (winner entered at the
    ///         same price/index as the estate, index fell 3 total: estate/vault side received,
    ///         winner side paid):
    ///           winner credit = price(100 − 88) + own tab(−3) = $9  ==  collateral($10) − window($1)
    ///         Insurance's single −$9 entry nets it +$1 vs the $10 seizure — exactly its window
    ///         receivable, collected through the winner's netted tab. Any explicit funding entry
    ///         on top would break this identity.
    function test_adlClose_preAndWindowFunding_noDoubleCount() public {
        // Estate: long 1 unit, entry $100, collateral $10, owed $2 at liquidation → bk $88.
        h.setPendingLiq(1 * SCALE, 88 * SCALE, true);
        h.setPendingLiqFundingIndex(0); // estate's entry index (Option 3 seeding)
        // Winner: short 1 unit, entry $100, $5 collateral, entry funding index 0.
        h.setBucket(winner, false, 1 * SCALE, 100 * SCALE, 5 * SCALE);
        h.setOI(0, 1 * SCALE, 0, 100 * SCALE);

        // Index fell 3 since entry (−2 before liquidation, −1 during the vault's window):
        // longs (estate, then vault) received; shorts (winner) paid.
        BazaarTypes.AdlParams memory params = BazaarTypes.AdlParams({
            adlLongs: false,
            adlSnapshotPrice: 88 * SCALE,
            adlSnapshotFundingIndex: -int256(3 * SCALE),
            adlPendingSince: block.timestamp - 15 minutes,
            currentPrice: 88 * SCALE,
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
        assertEq(h.bucketCollateral(winner), 14 * SCALE, "winner nets collateral - window funding via the two channels");
        assertEq(
            h.insurance(), 1_000e18 - 9e18, "single insurance entry; window funding is inside the 9, not booked again"
        );
        assertEq(h.vaultCollateral(), 1_000e18 + 9e18, "deposits ledger mirrors the single transfer");
        assertEq(h.pendingSize(), 0, "vault exposure cleared");
    }

    // ---------------- window-deposit score freeze (ADL queue dodging) ----------------

    /// @notice A deposit made DURING the live ADL window is subtracted from the scoring
    ///         collateral: the winner ranks on their pre-window book (here $1 → score 50e18,
    ///         eligible even at the near-max early-auction threshold), while settlement and the
    ///         payout still use their REAL post-deposit collateral. Mid-auction top-ups protect
    ///         the account; they cannot re-rank the queue.
    function test_windowDeposit_cannotDodgeAdlQueue() public {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);
        // Short winner: entry $150, pnl $50 at the $100 settlement. Real collateral $60 — of
        // which $59 was deposited during THIS window (epoch 7) to dodge: raw score would be
        // 50/60 ≈ 0.83e18, far below the early-auction threshold.
        h.setBucket(winner, false, 1 * SCALE, 150 * SCALE, 60 * SCALE);
        h.setAdlEpoch(7);
        h.setWindowDeposit(winner, 7, 59 * SCALE);

        // 1 minute into the auction: threshold is near max (~25e18) — only the frozen
        // pre-window score (50e18 on $1) clears it.
        h.execAdl(_one(winner), _params(100 * SCALE, 1));

        assertEq(h.bucketSize(winner), 0, "dodger closed despite the top-up");
        assertEq(h.bucketCollateral(winner), (60 + 50) * SCALE, "payout uses REAL collateral + pnl");
        assertEq(h.insurance(), 1_000e18 - 50e18, "winner credit funded once");
        assertEq(h.vaultCollateral(), 1_000e18 + 50e18, "I->D transfer mirrors the credit");
        assertEq(h.pendingSize(), 0, "vault exposure cleared");
    }

    /// @notice The withdraw-to-zero dodge is dead: a winner who pulled ALL collateral out
    ///         (equity gate passes on unrealized PnL alone) floors to 1-wei score collateral —
    ///         effectively infinite score — and is closable from the FIRST minute of the
    ///         auction, at the near-max threshold. Skipping zero-collateral buckets instead of
    ///         flooring them would make exactly these pure-profit accounts ADL-immune.
    function test_withdrawToZero_cannotDodgeAdlQueue() public {
        h.setPendingLiq(1 * SCALE, 100 * SCALE, true);
        h.setOI(0, 1 * SCALE, 0, 150 * SCALE);
        h.setBucket(winner, false, 1 * SCALE, 150 * SCALE, 0); // all collateral withdrawn

        // 1 minute into the auction — only near-infinite scores are eligible, and this is one.
        h.execAdl(_one(winner), _params(100 * SCALE, 1));

        assertEq(h.bucketSize(winner), 0, "pure-profit winner closed first");
        assertEq(h.bucketCollateral(winner), 50 * SCALE, "credit = pnl on zero real collateral");
        assertEq(h.insurance(), 1_000e18 - 50e18, "funded from insurance once");
        assertEq(h.pendingSize(), 0, "vault exposure cleared");
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

        // Sized so the vault stays unhealthy through BOTH closes (the mid-batch health check runs
        // before every close after the first): at currentPrice $50 the exposure left before B is
        // 6 units × ($100 bk − $50) = $300, above the 60% cancel threshold on $400 insurance
        // ($240). Insurance still covers both credits ($150) in full.
        h.setVaultInsurance(400e18);

        BazaarTypes.AdlParams memory params = BazaarTypes.AdlParams({
            adlLongs: false,
            adlSnapshotPrice: 100 * SCALE,
            adlSnapshotFundingIndex: 0, // frozen at auction trigger
            adlPendingSince: block.timestamp - 15 minutes, // threshold collapsed to 1
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
        assertEq(h.insurance(), 400e18 - 150e18, "insurance funded both credits");
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
            adlPendingSince: block.timestamp - 15 minutes,
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
