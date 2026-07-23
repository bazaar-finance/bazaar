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

    function setPendingLiq(uint256 size_, uint256 entry_, uint256 bk_, bool isLong_) external {
        pLiqSize = size_;
        pLiqEntry = entry_;
        pLiqBk = bk_;
        pLiqIsLong = isLong_;
    }

    function positionBuckets(address)
        external
        pure
        returns (bool, uint256, uint256, uint256, int256, uint256, uint256, uint256, uint256, uint256)
    {
        return (false, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    }

    function currentFundingIndex() external pure returns (int256) {
        return 0;
    }

    function marginRequirements() external pure returns (uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0);
    }

    function getLaggedMmrBp() external pure returns (uint256) {
        return 0;
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

    function auxState() external pure returns (BazaarTypes.AuxState memory a) {
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

    function test_getPendingLiquidationExposure_forwardsFields() public {
        pair.setPendingLiq(5 * SCALE, 250_000 * SCALE, 240_000 * SCALE, true);
        (uint256 size, uint256 entry, uint256 bk, bool isLong) = lens.getPendingLiquidationExposure(address(pair));
        assertEq(size, 5 * SCALE);
        assertEq(entry, 250_000 * SCALE);
        assertEq(bk, 240_000 * SCALE);
        assertTrue(isLong);
    }
}
