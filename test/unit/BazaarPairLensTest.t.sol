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
    uint256 public adlPendingSince;
    uint256 internal pLiqSize;
    uint256 internal pLiqEntry;
    uint256 internal pLiqBk;
    bool internal pLiqIsLong;
    mapping(address => BazaarTypes.PositionBucket) internal buckets;
    mapping(address => uint256) public adlScoreDeposit;
    mapping(address => uint256) public terminalProfitClaim;
    uint256 public fixedSettlementPrice;
    uint256 public settlementPriceFixedTs;
    bool public isPairTerminatedEmergency;
    uint256 internal snapPrice;
    int256 internal snapFundingIdx;
    bool internal snapAdlLongs;
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

    function setAdl(bool pending_, uint256 since_) external {
        isAdlPending = pending_;
        adlPendingSince = since_;
    }

    function setAdlSnapshot(uint256 price_, int256 fundingIdx_, bool adlLongs_) external {
        snapPrice = price_;
        snapFundingIdx = fundingIdx_;
        snapAdlLongs = adlLongs_;
    }

    function setBucket(address u, bool isLong_, uint256 size_, uint256 entryValue_, uint256 collateral_) external {
        BazaarTypes.PositionBucket storage b = buckets[u];
        b.isLong = isLong_;
        b.size = size_;
        b.entryValue = entryValue_;
        b.collateral = collateral_;
    }

    function setAdlScoreDeposit(address u, uint256 wd) external {
        adlScoreDeposit[u] = wd;
    }

    function setTerminalClaim(address u, uint256 claim) external {
        terminalProfitClaim[u] = claim;
    }

    function setTerminal(uint256 fixedPrice_, uint256 fixedTs_, uint256 ratioBp_) external {
        fixedSettlementPrice = fixedPrice_;
        settlementPriceFixedTs = fixedTs_;
        frozenProfitRatioBp = ratioBp_;
    }

    function setEmergencyTerminated(bool v) external {
        isPairTerminatedEmergency = v;
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

    function outstandingOrderExposure(address) external view returns (uint256, uint256) {
        return (longOrderExposure_, shortOrderExposure_);
    }

    function setPendingLiq(uint256 size_, uint256 entry_, uint256 bk_, bool isLong_) external {
        pLiqSize = size_;
        pLiqEntry = entry_;
        pLiqBk = bk_;
        pLiqIsLong = isLong_;
    }

    function positionBuckets(address u)
        external
        view
        returns (bool, uint256, uint256, uint256, int256, uint256, uint256, uint256, uint256, uint256)
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
            b.activeMarketOrderId,
            b.mmrUpdateTs
        );
    }

    function currentFundingIndex() external pure returns (int256) {
        return 0;
    }

    function marginRequirements() external view returns (uint256, uint256, uint256, uint256) {
        return (imrBp_, mmrBp_, 0, laggedMmrBp_);
    }

    function getLaggedMmrBp() external view returns (uint256) {
        return laggedMmrBp_;
    }

    function pairId() external pure returns (bytes32) {
        return bytes32(0);
    }

    function pairVault()
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, int256, bool, uint256)
    {
        return (0, 0, 0, 0, 0, insuranceFundBalance, pLiqSize, pLiqEntry, pLiqBk, int256(0), pLiqIsLong, 0);
    }

    function auxState() external view returns (BazaarTypes.AuxState memory a) {
        a.adlSnapshotPrice = snapPrice;
        a.adlSnapshotFundingIndex = snapFundingIdx;
        a.adlLongs = snapAdlLongs;
        a.normalTerminalWinnersPayoutRatioBp = frozenProfitRatioBp;
        return a;
    }
}

contract BazaarPairLensTest is Test {
    BazaarPairLens internal lens;
    MockPairForLens internal pair;
    uint256 constant SCALE = 1e18;
    uint256 constant DURATION = BazaarTypes.ADL_AUCTION_DURATION;

    function setUp() public {
        lens = new BazaarPairLens();
        pair = new MockPairForLens();
        vm.warp(1_000_000);
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
        (uint64 minL, uint64 mktL, uint64 maxL) = lens.getOrderLifetimeConstants();
        assertEq(minL, BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS);
        assertEq(mktL, BazaarTypes.MARKET_ORDER_LIFETIME_BLOCKS);
        assertEq(maxL, BazaarTypes.MAX_ORDER_LIFETIME_BLOCKS);
    }

    function test_getMinCollateralAmount() public view {
        assertEq(lens.getMinCollateralAmount(), CollateralLib.MIN_COLLATERAL_AMOUNT);
    }

    function test_getInsuranceWithdrawalConstants() public view {
        (uint256 cd, uint256 win, uint256 rlp, uint256 rlbp, uint256 aboveTargetBp, uint256 fundCapBp) =
            lens.getInsuranceWithdrawalConstants();
        assertEq(cd, InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN);
        assertEq(win, InsuranceVaultLib.INSURANCE_WITHDRAWAL_WINDOW);
        assertEq(rlp, InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_PERIOD);
        assertEq(rlbp, InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_BP);
        assertEq(aboveTargetBp, InsuranceVaultLib.INSURANCE_WITHDRAWAL_ABOVE_TARGET_RATE_LIMIT_BP);
        assertEq(fundCapBp, InsuranceVaultLib.INSURANCE_WITHDRAWAL_ABOVE_TARGET_FUND_CAP_BP);
    }

    function test_getVaultHealthConstants() public view {
        (uint256 trig, uint256 cancel, uint256 timeout, uint256 maxWinners) = lens.getVaultHealthConstants();
        assertEq(trig, VaultHealthLib.ADL_TRIGGER_THRESHOLD_BP);
        assertEq(cancel, VaultHealthLib.ADL_CANCEL_THRESHOLD_BP);
        assertEq(timeout, VaultHealthLib.ADL_TIMEOUT_DURATION);
        assertEq(maxWinners, AdlLib.MAX_ADL_WINNERS_PER_BATCH);
    }

    function test_getSequencerFlatFeePerSide() public view {
        assertEq(lens.getSequencerFlatFeePerSide(), BazaarTypes.SEQUENCER_FLAT_FEE_PER_SIDE);
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

    function test_getAdlScoreThreshold_notPending_isMax() public {
        pair.setAdl(false, block.timestamp);
        assertEq(lens.getAdlScoreThreshold(address(pair)), type(uint256).max);
    }

    function test_getAdlScoreThreshold_pendingSinceZero_isMax() public {
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

    // ---------------- terminal entitlement + settlement bounty ----------------

    function test_getTerminalEntitlement_windowRatioZero_payoutZero() public {
        pair.setBucket(WINNER, false, 0, 0, 500 * SCALE);
        pair.setTerminalClaim(WINNER, 100 * SCALE);
        pair.setTerminal(50_000 * SCALE, block.timestamp, 0); // window open, ratio not frozen yet
        (uint256 coll, uint256 claim, uint256 ratioBp, uint256 payout) =
            lens.getTerminalEntitlement(address(pair), WINNER);
        assertEq(coll, 500 * SCALE);
        assertEq(claim, 100 * SCALE, "claim registered during the window");
        assertEq(ratioBp, 0, "ratio not frozen until finalize");
        assertEq(payout, 0, "payout unknown until the ratio freezes");
    }

    function test_getTerminalEntitlement_frozenRatio_prorataPayout() public {
        pair.setBucket(WINNER, false, 0, 0, 500 * SCALE);
        pair.setTerminalClaim(WINNER, 100 * SCALE);
        pair.setTerminal(50_000 * SCALE, block.timestamp, 8_000); // finalized at 80%
        (uint256 coll, uint256 claim, uint256 ratioBp, uint256 payout) =
            lens.getTerminalEntitlement(address(pair), WINNER);
        assertEq(coll, 500 * SCALE);
        assertEq(claim, 100 * SCALE);
        assertEq(ratioBp, 8_000);
        assertEq(payout, 80 * SCALE, "100 claim x 80% ratio");
    }

    function test_getTerminalSettlementBounty_noWindowOrFlat_zero() public {
        pair.setBucket(WINNER, true, 1 * SCALE, 50_000 * SCALE, 100 * SCALE);
        (uint256 bounty, bool settleable) = lens.getTerminalSettlementBounty(address(pair), WINNER);
        assertEq(bounty, 0, "no settlement mode: no bounty");
        assertFalse(settleable);

        pair.setTerminal(50_000 * SCALE, block.timestamp, 0);
        (bounty, settleable) = lens.getTerminalSettlementBounty(address(pair), address(0xF1A7));
        assertEq(bounty, 0, "flat user: nothing to settle");
        assertFalse(settleable);
    }

    function test_getTerminalSettlementBounty_matchesOnchainFormula() public {
        pair.setTerminal(50_000 * SCALE, block.timestamp, 0);
        // Large position: 2 bp of the 1 BTC x $50k notional = $10.
        pair.setBucket(WINNER, true, 1 * SCALE, 50_000 * SCALE, 100 * SCALE);
        (uint256 bounty, bool settleable) = lens.getTerminalSettlementBounty(address(pair), WINNER);
        assertTrue(settleable);
        assertEq(bounty, 10 * SCALE, "2 bp of $50k notional");

        // Dust position: floors at MIN_LIQUIDATOR_REWARD ($0.10).
        pair.setBucket(WINNER, true, SCALE / 1_000_000, 5 * SCALE / 100, 1 * SCALE);
        (bounty,) = lens.getTerminalSettlementBounty(address(pair), WINNER);
        assertEq(bounty, SCALE / 10, "floored at the $0.10 minimum reward");
    }

    // ---------------- getMaxWithdrawable (mirrors the withdrawCollateral gates) ----------------

    function test_getMaxWithdrawable_flatNoOrders_fullCollateral() public {
        pair.setBucket(WINNER, false, 0, 0, 100 * SCALE);
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 0, false), 100 * SCALE);
    }

    function test_getMaxWithdrawable_flatWithOrders_reservesOrderImr() public {
        pair.setBucket(WINNER, false, 0, 0, 100 * SCALE);
        pair.setMarginReqs(1_000, 500, 500); // IMR 10%
        pair.setOrderExposure(50 * SCALE, 200 * SCALE); // larger side: $200 short
        assertEq(
            lens.getMaxWithdrawable(address(pair), WINNER, 0, false),
            80 * SCALE,
            "collateral less 10% of the larger resting side"
        );
        assertEq(
            lens.getMaxWithdrawable(address(pair), WINNER, 0, true),
            60 * SCALE,
            "stale oracle doubles the order-IMR reserve"
        );
    }

    function test_getMaxWithdrawable_position_imrSlackBinds() public {
        pair.setMarginReqs(1_000, 500, 500); // IMR 10%
        // Long 1 unit at $100 entry, price $100: equity = collateral = $20.
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);
        // Ceilings: collateral 20; floor max(0.5%x100, $5)=$5 -> 15; IMR slack 20 - 10%x100 = 10.
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 100 * SCALE, false), 10 * SCALE);
    }

    function test_getMaxWithdrawable_position_retentionFloorBinds() public {
        pair.setMarginReqs(1_000, 500, 500);
        // Long 1 unit at $100 entry, price $1000: equity $920 dwarfs the $100 IMR requirement.
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);
        // Ceilings: collateral 20; floor max(0.5%x1000, $5)=$5 -> 15; IMR slack 820.
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 1_000 * SCALE, false), 15 * SCALE);
    }

    function test_getMaxWithdrawable_position_orderExposureWidensImr() public {
        pair.setMarginReqs(1_000, 500, 500);
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);
        pair.setOrderExposure(50 * SCALE, 0); // same-direction resting orders
        // Worst case = $100 position + $50 same-dir orders -> IMR $15 -> slack $5.
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 100 * SCALE, false), 5 * SCALE);
    }

    function test_getMaxWithdrawable_frozenStates_zero() public {
        pair.setMarginReqs(1_000, 500, 500);
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);

        pair.setTerminal(100 * SCALE, block.timestamp, 0); // sweep window open
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 100 * SCALE, false), 0, "sweep window");
        pair.setTerminal(0, 0, 0);

        pair.setEmergencyTerminated(true);
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 100 * SCALE, false), 0, "emergency");
        pair.setEmergencyTerminated(false);

        pair.setAdl(true, block.timestamp);
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 100 * SCALE, false), 0, "ADL freezes position holders");
        pair.setBucket(WINNER, false, 0, 0, 100 * SCALE);
        assertEq(
            lens.getMaxWithdrawable(address(pair), WINNER, 0, false),
            100 * SCALE,
            "flat users stay withdrawable during ADL"
        );
    }

    function test_getMaxWithdrawable_underwaterPosition_zero() public {
        pair.setMarginReqs(1_000, 500, 500);
        // Long 1 unit at $100 entry, price $50: the $50 loss swamps the $20 collateral.
        pair.setBucket(WINNER, true, 1 * SCALE, 100 * SCALE, 20 * SCALE);
        assertEq(lens.getMaxWithdrawable(address(pair), WINNER, 50 * SCALE, false), 0);
    }

    function test_getLiquidationRewardConstants() public view {
        (uint256 minReward, uint256 feeEbp, uint256 ebpScale) = lens.getLiquidationRewardConstants();
        assertEq(minReward, BazaarTypes.MIN_LIQUIDATOR_REWARD);
        assertEq(feeEbp, BazaarTypes.LIQUIDATION_FEE_EBP);
        assertEq(ebpScale, BazaarTypes.EBP_SCALE);
    }

    function test_getPendingLiquidationExposure_forwardsFields() public {
        pair.setPendingLiq(5 * SCALE, 250_000 * SCALE, 240_000 * SCALE, true);
        (uint256 size, uint256 entry, uint256 bk, bool isLong) = lens.getPendingLiquidationExposure(address(pair));
        assertEq(size, 5 * SCALE);
        assertEq(entry, 250_000 * SCALE);
        assertEq(bk, 240_000 * SCALE);
        assertTrue(isLong);
    }
}
