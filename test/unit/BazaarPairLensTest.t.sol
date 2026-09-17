// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarPairLens} from "../../src/BazaarPairLens.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";
import {CollateralLib} from "../../src/libraries/CollateralLib.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";
import {VaultHealthLib} from "../../src/libraries/VaultHealthLib.sol";
import {AdlLib} from "../../src/libraries/AdlLib.sol";

/// @notice Minimal stand-in exposing only the IBazaarPairLens selectors the Lens reads, with
///         settable state — lets us drive the Lens's computed getters without a full pair deploy.
contract MockPairForLens {
    uint256 public totalInsuranceShares;
    uint256 public insuranceFundBalance;
    mapping(address => uint256) public insuranceShares;
    bool public isAdlPending;
    bool public isContinuouslyTraded = true;
    uint256 public adlPendingSince;
    uint256 public adlAuctionStartTs;
    uint256 internal pLiqSize;
    uint256 internal pLiqEntry;
    uint256 internal pLiqBk;
    int256 internal pLiqFundingIdx;
    bool internal pLiqIsLong;
    mapping(address => BazaarTypes.PositionBucket) internal buckets;
    mapping(address => uint256) public adlScoreDeposit;
    mapping(address => uint256) public terminalProfitClaim;
    uint256 public fixedSettlementPrice;
    uint256 public settlementPriceFixedTs;
    uint256 internal snapPrice;
    int256 internal snapFundingIdx;
    bool internal snapAdlLongs;
    uint256 internal frozenPrincipalRatioBp;
    uint256 internal frozenProfitRatioBp;
    uint256 internal imrBp_;
    uint256 internal mmrBp_;
    uint256 internal laggedMmrBp_;
    uint256 internal longOrderExposure_;
    uint256 internal shortOrderExposure_;

    function setInsurance(uint256 shares_, uint256 fund_) external {
        totalInsuranceShares = shares_;
        insuranceFundBalance = fund_;
    }

    function setUserShares(address u, uint256 s) external {
        insuranceShares[u] = s;
    }

    mapping(address => uint256) internal claimable_;
    uint256 internal claimableTotal_;

    function setClaimable(address who, uint256 amount) external {
        claimableTotal_ = claimableTotal_ - claimable_[who] + amount;
        claimable_[who] = amount;
    }

    function claimableFees(address who) external view returns (uint256 owed, uint256 total) {
        return (claimable_[who], claimableTotal_);
    }

    /// @dev Sets both clocks to `since_`: they coincide on an auction no discontinuity has
    ///      restarted, which is the case every threshold test here exercises. The lens reads
    ///      adlAuctionStartTs — adlPendingSince dates the window and drives termination instead.
    function setAdl(bool pending_, uint256 since_) external {
        isAdlPending = pending_;
        adlPendingSince = since_;
        adlAuctionStartTs = since_;
    }

    function setAdlSnapshot(uint256 price_, int256 fundingIdx_, bool adlLongs_) external {
        snapPrice = price_;
        snapFundingIdx = fundingIdx_;
        snapAdlLongs = adlLongs_;
    }

    function setBucket(address u, bool isLong_, uint256 size_, uint256 entryValue_, uint256 collateral_) external {
        BazaarTypes.PositionBucket storage b = buckets[u];
        b.isLong = isLong_;
        b.size = uint128(size_);
        b.entryValue = uint128(entryValue_);
        b.collateral = uint128(collateral_);
    }

    function setAdlScoreDeposit(address u, uint256 wd) external {
        adlScoreDeposit[u] = wd;
    }

    function setTerminalClaim(address u, uint256 claim) external {
        terminalProfitClaim[u] = claim;
    }

    function setTerminal(uint256 fixedPrice_, uint256 fixedTs_, uint256 principalBp_, uint256 profitBp_) external {
        fixedSettlementPrice = fixedPrice_;
        settlementPriceFixedTs = fixedTs_;
        frozenPrincipalRatioBp = principalBp_;
        frozenProfitRatioBp = profitBp_;
    }

    function setContinuouslyTraded(bool v) external {
        isContinuouslyTraded = v;
    }

    function setMarginReqs(uint256 imrBp, uint256 mmrBp, uint256 laggedMmrBp) external {
        imrBp_ = imrBp;
        mmrBp_ = mmrBp;
        laggedMmrBp_ = laggedMmrBp;
    }

    function setOrderExposure(uint256 longExp, uint256 shortExp) external {
        longOrderExposure_ = longExp;
        shortOrderExposure_ = shortExp;
    }

    function outstandingOrderExposure(address) external view returns (uint256, uint256, uint256, uint256) {
        // Sizes stay 0: the lens's reserve-at-mark max is a no-op here, so these tests pin the
        // ceiling math against the exposure values exactly as set.
        return (longOrderExposure_, shortOrderExposure_, 0, 0);
    }

    function setPendingLiq(uint256 size_, uint256 entry_, uint256 bk_, bool isLong_) external {
        pLiqSize = size_;
        pLiqEntry = entry_;
        pLiqBk = bk_;
        pLiqIsLong = isLong_;
    }

    function setPendingLiqFundingIndex(int256 idx_) external {
        pLiqFundingIdx = idx_;
    }

    uint256 internal pLiqSeized;
    uint256 internal targetInsuranceRatioBp_;
    uint256 internal mark_;

    function setPendingLiqSeized(uint256 seized_) external {
        pLiqSeized = seized_;
    }

    function setTargetInsuranceRatioBp(uint256 bp) external {
        targetInsuranceRatioBp_ = bp;
    }

    function setMark(uint256 price_) external {
        mark_ = price_;
    }

    function lastPairPrice() external view returns (uint256, uint256, uint256, uint256, uint256) {
        return (mark_, 0, 0, 0, 0);
    }

    function positionBuckets(address u)
        external
        view
        returns (bool, uint256, uint256, uint256, int256, uint256, uint256, uint256, uint256)
    {
        BazaarTypes.PositionBucket storage b = buckets[u];
        return (
            b.isLong,
            b.size,
            b.entryValue,
            b.collateral,
            b.entryFundingIndex,
            b.takeProfitOrderId,
            b.stopLossOrderId,
            b.entryMmrBp,
            b.mmrUpdateTs
        );
    }

    function currentFundingIndex() external pure returns (int256) {
        return 0;
    }

    function marginRequirements() external view returns (uint256, uint256, uint256, uint256, uint256) {
        return (imrBp_, mmrBp_, 0, laggedMmrBp_, 0);
    }

    /// @dev Sample timestamp 0: setBucket leaves mmrUpdateTs at 0, so effectiveMmr's guard keeps
    ///      every bucket here on the entry branch and the lagged rate is inert either way.
    function getLaggedMmr() external view returns (uint256, uint256) {
        return (laggedMmrBp_, 0);
    }

    function pairId() external pure returns (bytes32) {
        return bytes32(0);
    }

    function pairVault()
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            int256,
            bool,
            uint256,
            uint256,
            uint256
        )
    {
        return (
            0,
            0,
            0,
            0,
            0,
            insuranceFundBalance,
            pLiqSize,
            pLiqEntry,
            pLiqBk,
            pLiqFundingIdx,
            pLiqIsLong,
            0,
            targetInsuranceRatioBp_,
            pLiqSeized
        );
    }

    function auxState() external view returns (BazaarTypes.AuxState memory a) {
        a.adlSnapshotPrice = snapPrice;
        a.adlSnapshotFundingIndex = snapFundingIdx;
        a.adlLongs = snapAdlLongs;
        a.settlementPrice = fixedSettlementPrice;
        a.terminalPrincipalRatioBp = frozenPrincipalRatioBp;
        a.terminalProfitRatioBp = frozenProfitRatioBp;
        return a;
    }
}

/// @dev Stands in for BazaarFactory: the lens only reads getAllPairs() from it.
contract MockFactoryForLens {
    address[] internal pairs;

    function addPair(address p) external {
        pairs.push(p);
    }

    function getAllPairs() external view returns (address[] memory) {
        return pairs;
    }
}

contract BazaarPairLensTest is Test {
    BazaarPairLens internal lens;
    MockPairForLens internal pair;
    MockFactoryForLens internal factory;
    uint256 constant SCALE = 1e18;
    uint256 constant DURATION = BazaarTypes.ADL_AUCTION_DURATION;

    function setUp() public {
        factory = new MockFactoryForLens();
        lens = new BazaarPairLens(address(factory));
        pair = new MockPairForLens();
        vm.warp(1_000_000);
    }

    // ---------------- fee escrow views ----------------

    function test_constructor_revertsOnZeroFactory() public {
        vm.expectRevert(BazaarPairLens.BazaarPairLens__ZeroAddress.selector);
        new BazaarPairLens(address(0));
    }

    function test_factory_isTheWiredAddress() public view {
        assertEq(lens.factory(), address(factory));
    }

    /// @notice One read per pair, in the order passed, straight from each pair's own getter.
    function test_getClaimableFees_readsEachPairInOrder() public {
        MockPairForLens other = new MockPairForLens();
        address who = makeAddr("keeper");
        pair.setClaimable(who, 3e18);
        other.setClaimable(who, 5e17);

        address[] memory pairs = new address[](2);
        pairs[0] = address(other);
        pairs[1] = address(pair);
        uint256[] memory owed = lens.getClaimableFees(pairs, who);

        assertEq(owed.length, 2);
        assertEq(owed[0], 5e17, "first entry follows the first pair passed");
        assertEq(owed[1], 3e18, "second entry follows the second pair passed");
        assertEq(lens.getClaimableFees(pairs, makeAddr("nobody"))[0], 0, "a stranger is owed nothing");
    }

    /// @notice The whole pair set of the wired factory as parallel arrays, zero entries included.
    function test_getClaimableFeesAll_enumeratesTheWiredFactory() public {
        MockPairForLens other = new MockPairForLens();
        address who = makeAddr("relayer");
        pair.setClaimable(who, 1e18);
        factory.addPair(address(pair));
        factory.addPair(address(other));

        (address[] memory pairs, uint256[] memory owed) = lens.getClaimableFeesAll(who);

        assertEq(pairs.length, 2);
        assertEq(owed.length, 2);
        assertEq(pairs[0], address(pair));
        assertEq(owed[0], 1e18, "owed on the first pair");
        assertEq(pairs[1], address(other));
        assertEq(owed[1], 0, "unfiltered: a zero balance is still listed");
    }

    function test_getClaimableFeesAll_emptyFactory() public view {
        (address[] memory pairs, uint256[] memory owed) = lens.getClaimableFeesAll(address(0xBEEF));
        assertEq(pairs.length, 0);
        assertEq(owed.length, 0);
    }

    // ---------------- constant forwarders (must forward the correct constant) ----------------

    function test_getEip712Constants() public view {
        (bytes32 dom, bytes32 nameH, bytes32 verH, uint256 maxFee, uint256 maxWin) = lens.getEip712Constants();
        assertEq(dom, MetaTxLib.EIP712_DOMAIN_TYPEHASH);
        assertEq(nameH, MetaTxLib.NAME_HASH);
        assertEq(verH, MetaTxLib.VERSION_HASH);
        assertEq(maxFee, MetaTxLib.MAX_RELAYER_FEE);
        assertEq(maxWin, MetaTxLib.MAX_DEADLINE_WINDOW);
    }

    function test_getTypehashes() public view {
        (bytes32 dep, bytes32 wd, bytes32 di, bytes32 ei, bytes32 co, bytes32 ca, bytes32 ri) = lens.getTypehashes();
        assertEq(dep, MetaTxLib.DEPOSIT_COLLATERAL_TYPEHASH);
        assertEq(wd, MetaTxLib.WITHDRAW_COLLATERAL_TYPEHASH);
        assertEq(di, MetaTxLib.DEPOSIT_TO_INSURANCE_TYPEHASH);
        assertEq(ei, MetaTxLib.EXECUTE_INSURANCE_WITHDRAWAL_TYPEHASH);
        assertEq(co, MetaTxLib.CREATE_ORDER_TYPEHASH);
        assertEq(ca, MetaTxLib.CANCEL_ORDERS_TYPEHASH);
        assertEq(ri, MetaTxLib.REQUEST_INSURANCE_WITHDRAWAL_TYPEHASH);
    }

    function test_getOrderLifetimeConstants() public view {
        (uint64 minL, uint64 maxL) = lens.getOrderLifetimeConstants();
        assertEq(minL, BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS);
        assertEq(maxL, BazaarTypes.MAX_ORDER_LIFETIME_BLOCKS);
    }

    function test_getMinCollateralAmount() public view {
        assertEq(lens.getMinCollateralAmount(), CollateralLib.MIN_COLLATERAL_AMOUNT);
    }

    function test_getInsuranceWithdrawalConstants() public view {
        (
            uint256 cd,
            uint256 win,
            uint256 rlp,
            uint256 rlbp,
            uint256 aboveTargetBp,
            uint256 fundCapBp,
            uint256 belowTargetFundCapBp
        ) = lens.getInsuranceWithdrawalConstants();
        assertEq(cd, InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN);
        assertEq(win, InsuranceVaultLib.INSURANCE_WITHDRAWAL_WINDOW);
        assertEq(rlp, InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_PERIOD);
        assertEq(rlbp, InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_BP);
        assertEq(aboveTargetBp, InsuranceVaultLib.INSURANCE_WITHDRAWAL_ABOVE_TARGET_RATE_LIMIT_BP);
        assertEq(fundCapBp, InsuranceVaultLib.INSURANCE_WITHDRAWAL_ABOVE_TARGET_FUND_CAP_BP);
        assertEq(belowTargetFundCapBp, InsuranceVaultLib.INSURANCE_WITHDRAWAL_BELOW_TARGET_FUND_CAP_BP);
    }

    function test_getVaultHealthConstants() public view {
        (uint256 reserveBp, uint256 bandCapBp, uint256 timeout, uint256 maxWinners) = lens.getVaultHealthConstants();
        assertEq(reserveBp, BazaarTypes.ADL_RESERVE_BP);
        assertEq(bandCapBp, BazaarTypes.LIQ_MAX_SLIPPAGE_BP);
        assertEq(timeout, VaultHealthLib.ADL_TIMEOUT_DURATION);
        assertEq(maxWinners, AdlLib.MAX_ADL_WINNERS_PER_BATCH);
    }

    // ---------------- computed getters (real logic, via the mock) ----------------

    function test_getInsuranceSharePrice_noShares_isUnitPrice() public view {
        assertEq(lens.getInsuranceSharePrice(address(pair)), SCALE, "no shares => 1.0 price");
    }

    function test_getInsuranceSharePrice_reflectsFundPerShare() public {
        pair.setInsurance(100 * SCALE, 150 * SCALE); // shares, fund
        assertEq(lens.getInsuranceSharePrice(address(pair)), 15 * SCALE / 10, "150/100 = 1.5");
    }

    function test_getInsuranceDepositValue_zeroWhenNoShares() public view {
        assertEq(lens.getInsuranceDepositValue(address(pair), address(this)), 0);
    }

    function test_getInsuranceDepositValue_prorataOfFund() public {
        pair.setInsurance(100 * SCALE, 150 * SCALE);
        pair.setUserShares(address(this), 20 * SCALE);
        // 20 shares * 150 fund / 100 total = 30
        assertEq(lens.getInsuranceDepositValue(address(pair), address(this)), 30 * SCALE);
    }

    /// @notice With inventory whole at the stored mark, the seizure is netted out of the basis and
    ///         its recovery is not paid to a leaver: shares redeem at free capital.
    function test_getInsuranceSharePrice_netsSeizure_ignoresGain() public {
        pair.setInsurance(100 * SCALE, 150 * SCALE); // 100 free once 50 is seized
        pair.setPendingLiq(1 * SCALE, 50 * SCALE, 0, true); // one unit long from 50
        pair.setPendingLiqSeized(50 * SCALE);
        pair.setMark(50 * SCALE); // at entry: net +50, a gain a redemption never collects
        assertEq(lens.getInsuranceSharePrice(address(pair)), SCALE, "free 100 / 100 shares");
        pair.setUserShares(address(this), 20 * SCALE);
        assertEq(lens.getInsuranceDepositValue(address(pair), address(this)), 20 * SCALE, "20 shares at 1.0");
    }

    /// @notice An inventory loss at the stored mark comes off the redemption basis, as far as the
    ///         fund bears it: with no reserve the whole loss counts.
    function test_getInsuranceSharePrice_subtractsInventoryLoss() public {
        pair.setInsurance(100 * SCALE, 150 * SCALE);
        pair.setPendingLiq(1 * SCALE, 60 * SCALE, 10 * SCALE, true); // one unit long from 60
        pair.setPendingLiqSeized(50 * SCALE);
        pair.setMark(5 * SCALE); // pnl -55, net -5: the fund bears 5
        assertEq(lens.getInsuranceSharePrice(address(pair)), 95 * SCALE / 100, "(100 - 5) / 100");
    }

    /// @notice Deposit quotes at a caller-supplied mark: the inventory's gain raises the basis and
    ///         its loss lowers it, both in full while the fund can bear them.
    function test_quoteInsuranceDeposit_gainAndLoss() public {
        pair.setInsurance(100 * SCALE, 150 * SCALE); // 140 free once 10 is seized
        pair.setPendingLiq(10 * SCALE, 500 * SCALE, 490 * SCALE, true); // ten units long from 50
        pair.setPendingLiqSeized(10 * SCALE);
        // Mark 52: pnl +20, net +30 -> basis 170.
        assertEq(lens.quoteInsuranceDeposit(address(pair), 17 * SCALE, 52 * SCALE), 10 * SCALE, "17 / 1.7");
        // Mark 48: pnl -20, net -10 -> basis 130.
        assertEq(lens.quoteInsuranceDeposit(address(pair), 13 * SCALE, 48 * SCALE), 10 * SCALE, "13 / 1.3");
    }

    /// @notice The loss deduction stops at free capital above the reserve. With a 100% target the
    ///         reserve on ten units at 40 is 80, so of a 90 loss the fund bears 60 and the basis is
    ///         the reserve itself; a redemption and the stored-mark view price off the same figure.
    function test_quoteInsurance_lossCappedAtFreeAboveReserve() public {
        pair.setInsurance(100 * SCALE, 150 * SCALE);
        pair.setPendingLiq(10 * SCALE, 500 * SCALE, 490 * SCALE, true);
        pair.setPendingLiqSeized(10 * SCALE);
        pair.setTargetInsuranceRatioBp(10_000);
        assertEq(lens.quoteInsuranceDeposit(address(pair), 8 * SCALE, 40 * SCALE), 10 * SCALE, "8 / 0.8");
        assertEq(lens.quoteInsuranceWithdrawal(address(pair), 20 * SCALE, 40 * SCALE), 16 * SCALE, "20 x 0.8");
        pair.setMark(40 * SCALE);
        assertEq(lens.getInsuranceSharePrice(address(pair)), 8 * SCALE / 10, "0.8 at the stored mark");
    }

    /// @notice Quotes mirror the pair's par branches: an empty pool, or one a realized wipe is
    ///         about to reset, mints 1:1.
    function test_quoteInsuranceDeposit_parOnEmptyOrWipedPool() public {
        assertEq(lens.quoteInsuranceDeposit(address(pair), 7 * SCALE, 50 * SCALE), 7 * SCALE, "empty pool: par");
        pair.setInsurance(100 * SCALE, SCALE / 2); // live shares over a fund below $1
        assertEq(lens.quoteInsuranceDeposit(address(pair), 7 * SCALE, 50 * SCALE), 7 * SCALE, "wiped pool: par");
    }

    function test_getAdlScoreThreshold_notPending_isMax() public {
        pair.setAdl(false, block.timestamp);
        assertEq(lens.getAdlScoreThreshold(address(pair)), type(uint256).max);
    }

    function test_getAdlScoreThreshold_auctionStartZero_isMax() public {
        pair.setAdl(true, 0);
        assertEq(lens.getAdlScoreThreshold(address(pair)), type(uint256).max);
    }

    function test_getAdlScoreThreshold_atStart_isMaxScore() public {
        pair.setAdl(true, block.timestamp); // elapsed 0 => remaining^2/duration^2 = 1
        assertEq(lens.getAdlScoreThreshold(address(pair)), 1 + 25 * SCALE);
    }

    function test_getAdlScoreThreshold_afterAuction_isOne() public {
        pair.setAdl(true, block.timestamp);
        vm.warp(block.timestamp + DURATION); // elapsed == duration
        assertEq(lens.getAdlScoreThreshold(address(pair)), 1);
    }

    function test_getAdlScoreThreshold_decaysMonotonically() public {
        pair.setAdl(true, block.timestamp);
        uint256 t0 = block.timestamp;
        uint256 start = lens.getAdlScoreThreshold(address(pair));
        vm.warp(t0 + DURATION / 2);
        uint256 mid = lens.getAdlScoreThreshold(address(pair));
        vm.warp(t0 + DURATION);
        uint256 end = lens.getAdlScoreThreshold(address(pair));
        assertGt(start, mid, "decays over the auction");
        assertGt(mid, end);
        assertEq(end, 1);
    }

    // ---------------- getAdlScore (mirrors AdlLib's Pass-1 ranking) ----------------

    address constant WINNER = address(0xA11CE);

    /// @dev Canonical scenario: LONGS were liquidated, so winners are SHORTS (adlLongs=false).
    ///      Snapshot $100; a short from $150 entry carries $50 snapshot PnL per unit.
    function _setupAdlWindow() internal {
        pair.setAdl(true, block.timestamp);
        pair.setAdlSnapshot(100 * SCALE, 0, false);
        vm.warp(block.timestamp + DURATION); // decayed threshold = 1: any positive score is eligible
    }

    function test_getAdlScore_notPending_zero() public {
        pair.setAdlSnapshot(100 * SCALE, 0, false);
        pair.setBucket(WINNER, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        (uint256 score, bool eligible) = lens.getAdlScore(address(pair), WINNER);
        assertEq(score, 0, "no ADL pending: no score");
        assertFalse(eligible);
    }

    function test_getAdlScore_flatWrongSideOrLoser_zero() public {
        _setupAdlWindow();
        // Flat.
        (uint256 score, bool eligible) = lens.getAdlScore(address(pair), address(0xF1A7));
        assertEq(score, 0, "flat user");
        assertFalse(eligible);
        // Wrong side (long when winners are shorts).
        pair.setBucket(WINNER, true, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        (score, eligible) = lens.getAdlScore(address(pair), WINNER);
        assertEq(score, 0, "wrong side");
        assertFalse(eligible);
        // Right side but losing at the snapshot (short from $90 entry, snapshot $100).
        pair.setBucket(WINNER, false, 1 * SCALE, 90 * SCALE, 10 * SCALE);
        (score, eligible) = lens.getAdlScore(address(pair), WINNER);
        assertEq(score, 0, "non-positive snapshot PnL");
        assertFalse(eligible);
    }

    function test_getAdlScore_normalWinner_pnlOverCollateral() public {
        _setupAdlWindow();
        pair.setBucket(WINNER, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        (uint256 score, bool eligible) = lens.getAdlScore(address(pair), WINNER);
        assertEq(score, 5 * SCALE, "$50 pnl / $10 collateral = 5.0");
        assertTrue(eligible, "past the auction: threshold 1");
    }

    function test_getAdlScore_windowDeposit_subtractedFromDenominator() public {
        _setupAdlWindow();
        pair.setBucket(WINNER, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        pair.setAdlScoreDeposit(WINNER, 9 * SCALE); // mid-window top-up: ranked on $1 pre-window collateral
        (uint256 score,) = lens.getAdlScore(address(pair), WINNER);
        assertEq(score, 50 * SCALE, "$50 pnl / ($10 - $9) = 50.0");
    }

    function test_getAdlScore_zeroCollateral_flooredDenominator() public {
        _setupAdlWindow();
        pair.setBucket(WINNER, false, 1 * SCALE, 150 * SCALE, 0);
        (uint256 score, bool eligible) = lens.getAdlScore(address(pair), WINNER);
        // Pure-profit claim: denominator floors at 1 wei, ranking effectively infinite.
        assertEq(score, 50 * SCALE * SCALE, "$50 pnl / 1 wei");
        assertTrue(eligible);
    }

    function test_getAdlScore_belowDecayingThreshold_scoredButIneligible() public {
        pair.setAdl(true, block.timestamp); // auction just opened: threshold = 1 + 25e18
        pair.setAdlSnapshot(100 * SCALE, 0, false);
        pair.setBucket(WINNER, false, 1 * SCALE, 150 * SCALE, 10 * SCALE);
        (uint256 score, bool eligible) = lens.getAdlScore(address(pair), WINNER);
        assertEq(score, 5 * SCALE, "score is reported either way");
        assertFalse(eligible, "5.0 < opening threshold");
    }

    // ---------------- terminal entitlement ----------------

    function test_getTerminalEntitlement_windowOpen_payoutZero() public {
        pair.setBucket(WINNER, false, 0, 0, 500 * SCALE);
        pair.setTerminalClaim(WINNER, 100 * SCALE);
        pair.setTerminal(50_000 * SCALE, block.timestamp, 0, 0); // window open, ratios not frozen yet
        (uint256 coll, uint256 claim, uint256 principalBp, uint256 profitBp, uint256 payout) =
            lens.getTerminalEntitlement(address(pair), WINNER);
        assertEq(coll, 500 * SCALE);
        assertEq(claim, 100 * SCALE, "claim registered during the window");
        assertEq(principalBp, 0, "ratios not frozen until finalize");
        assertEq(profitBp, 0);
        assertEq(payout, 0, "payout unknown until finalize");
    }

    function test_getTerminalEntitlement_frozenRatios_payout() public {
        pair.setBucket(WINNER, false, 0, 0, 500 * SCALE);
        pair.setTerminalClaim(WINNER, 100 * SCALE);
        pair.setTerminal(50_000 * SCALE, block.timestamp, 10_000, 8_000); // finalized: profits at 80%
        (uint256 coll, uint256 claim, uint256 principalBp, uint256 profitBp, uint256 payout) =
            lens.getTerminalEntitlement(address(pair), WINNER);
        assertEq(coll, 500 * SCALE);
        assertEq(claim, 100 * SCALE);
        assertEq(principalBp, 10_000);
        assertEq(profitBp, 8_000);
        assertEq(payout, 580 * SCALE, "500 principal + 100 claim x 80%");

        pair.setTerminal(50_000 * SCALE, block.timestamp, 7_500, 0); // cash short of principal
        (,,,, payout) = lens.getTerminalEntitlement(address(pair), WINNER);
        assertEq(payout, 375 * SCALE, "500 x 75%, claim pays nothing");
    }

    // ---------------- getMaxWithdrawable (mirrors the withdrawCollateral gates) ----------------

    function test_getMaxWithdrawable_flatNoOrders_fullCollateral() public {
        pair.setBucket(WINNER, false, 0, 0, 100 * SCALE);
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 0), 100 * SCALE);
    }

    function test_getMaxWithdrawable_flatWithOrders_reservesOrderImr() public {
        pair.setBucket(WINNER, false, 0, 0, 100 * SCALE);
        pair.setMarginReqs(1_000, 500, 500); // IMR 10%
        pair.setOrderExposure(50 * SCALE, 200 * SCALE); // larger side: $200 short
        assertEq(
            lens.getMaxWithdrawable(address(pair), WINNER, 0),
            80 * SCALE,
            "collateral less 10% of the larger resting side"
        );
    }

    function test_getMaxWithdrawable_position_imrSlackBinds() public {
        pair.setMarginReqs(1_000, 500, 500); // IMR 10%
        // Long 1 unit at $100 entry, price $100: equity = collateral = $20.
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);
        // Ceilings: collateral 20; floor mmr 5% x 100 = $5 -> 15; IMR slack 20 - 10%x100 = 10.
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 100 * SCALE), 10 * SCALE);
    }

    function test_getMaxWithdrawable_position_retentionFloorBinds() public {
        pair.setMarginReqs(1_000, 500, 500);
        // Long 1 unit at $100 entry, price $300: equity $220 dwarfs the $30 IMR requirement.
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);
        // Ceilings: collateral 20; floor mmr 5% x 300 = $15 -> 5; IMR slack 220 - 30 = 190.
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 300 * SCALE), 5 * SCALE);

        // Deeper in profit the floor exceeds the cash on hand: nothing is withdrawable.
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 1_000 * SCALE), 0);
    }

    function test_getMaxWithdrawable_position_nonContinuous_imrCashFloor() public {
        pair.setMarginReqs(1_000, 500, 500);
        pair.setContinuouslyTraded(false);
        // Long 1 unit at $100 entry, price $300: session-bound pairs retain imrBp in cash, so the
        // floor is 10% x 300 = $30 — above the $20 of collateral, nothing is withdrawable even
        // though equity ($220) dwarfs the IMR requirement ($30).
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 300 * SCALE), 0);

        // With $50 of cash the same floor leaves $20 free (IMR slack is far looser at 220).
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 50 * SCALE);
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 300 * SCALE), 20 * SCALE);
    }

    function test_getMaxWithdrawable_position_orderExposureWidensImr() public {
        pair.setMarginReqs(1_000, 500, 500);
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);
        pair.setOrderExposure(50 * SCALE, 0); // same-direction resting orders
        // Worst case = $100 position + $50 same-dir orders -> IMR $15 -> slack $5.
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 100 * SCALE), 5 * SCALE);
    }

    function test_getMaxWithdrawable_frozenStates_zero() public {
        pair.setMarginReqs(1_000, 500, 500);
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);

        pair.setTerminal(100 * SCALE, block.timestamp, 0, 0); // settlement window open
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 100 * SCALE), 0, "settlement window");
        pair.setTerminal(0, 0, 0, 0);

        pair.setAdl(true, block.timestamp);
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 100 * SCALE), 0, "ADL freezes position holders");
        pair.setBucket(WINNER, false, 0, 0, 100 * SCALE);
        assertEq(
            lens.getMaxWithdrawable(address(pair), WINNER, 0), 100 * SCALE, "flat users stay withdrawable during ADL"
        );
    }

    function test_getMaxWithdrawable_underwaterPosition_zero() public {
        pair.setMarginReqs(1_000, 500, 500);
        // Long 1 unit at $100 entry, price $50: the $50 loss swamps the $20 collateral.
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 50 * SCALE), 0);
    }

    function test_getLiquidationRewardConstants() public view {
        (uint256 minReward, uint256 feeEbp, uint256 ebpScale) = lens.getLiquidationRewardConstants();
        assertEq(minReward, BazaarTypes.MIN_LIQUIDATOR_REWARD);
        assertEq(feeEbp, BazaarTypes.LIQUIDATION_FEE_EBP);
        assertEq(ebpScale, BazaarTypes.EBP_SCALE);
    }

    /// @notice The entry funding index has to come through with the notionals: without it a
    ///         caller can only rebuild the price half of the vault's PnL.
    function test_getPendingLiquidationExposure_forwardsFields() public {
        pair.setPendingLiq(5 * SCALE, 250_000 * SCALE, 240_000 * SCALE, true);
        pair.setPendingLiqFundingIndex(-7 * int256(SCALE));
        (uint256 size, uint256 entry, uint256 bk, int256 fundingIdx, bool isLong) =
            lens.getPendingLiquidationExposure(address(pair));
        assertEq(size, 5 * SCALE);
        assertEq(entry, 250_000 * SCALE);
        assertEq(bk, 240_000 * SCALE);
        assertEq(fundingIdx, -7 * int256(SCALE), "entry funding index forwarded, sign preserved");
        assertTrue(isLong);
    }
}
