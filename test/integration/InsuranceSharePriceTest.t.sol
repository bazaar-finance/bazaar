// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @title InsuranceSharePriceTest
/// @notice Share pricing against the fund's value at the mark while the vault holds inventory.
///         Both bases start from free capital — the fund less the collateral seized alongside
///         the inventory, which leaves again when it unloads — and add the inventory's
///         unrealized result: a redemption counts the loss the fund bears and never a gain, and a
///         deposit counts both and refuses a stale mark. Past free capital above the reserve the
///         ADL takes the rest of a loss from winners, and a deposit is refused there.
contract InsuranceSharePriceTest is IntegrationBase {
    uint256 constant MARK = 50_000 * BAZAAR_SCALE; // the BTC mark every fresh update here carries
    uint256 constant AAPL_MARK = 150 * BAZAAR_SCALE;

    function _insuranceBalance() internal view returns (uint256 b) {
        (,,,,, b,,,,,,,,,,,) = pair.pairVault();
    }

    function _fundOf(BazaarPair target) internal view returns (uint256 b) {
        (,,,,, b,,,,,,,,,,,) = target.pairVault();
    }

    function _requestAll(address user) internal returns (uint256 shares) {
        shares = pair.insuranceShares(user);
        vm.prank(user);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");
    }

    /// @dev A full live-pair redemption at the $50k mark: the lock, then the paying call once it
    ///      opens.
    function _execute(address user) internal {
        _redeemAt(user, 50_000);
    }

    /// @dev Stage the vault long one unit with `seized` banked alongside it, at the entry that
    ///      puts its net position at `mark` (seizure plus PnL from entry) at `net` before the
    ///      funding leg. Returns the entry notional so expected values can be recomputed with the
    ///      pair's live funding index.
    function _stageNet(BazaarPair target, uint256 mark, uint256 seized, int256 net) internal returns (uint256 entry) {
        entry = uint256(int256(mark) + int256(seized) - net);
        _stageHeldInventory(target, entry, seized);
    }

    /// @dev The staged unit's net position at `mark`, funding leg included: what the pair values
    ///      the inventory at when it prices shares.
    function _netAt(BazaarPair target, uint256 entry, uint256 seized, uint256 mark) internal view returns (int256) {
        return int256(seized) + int256(mark) - int256(entry) - target.currentFundingIndex();
    }

    /// @dev Reserve the unload walk keeps: ADL_RESERVE_BP of the target on the one staged unit at
    ///      `mark`, with no other open interest.
    function _reserveAt(uint256 mark, uint256 targetBp) internal pure returns (uint256) {
        return mark * targetBp * BazaarTypes.ADL_RESERVE_BP / 1e8;
    }

    function _cachedTargetBp() internal view returns (uint256 t) {
        (,,,,,,,,,,,, t,,,,) = pair.pairVault();
    }

    /// @dev Direct deposit into `target` carrying `pu` as the price update.
    function _depositWith(BazaarPair target, address user, uint256 amount, bytes[] memory pu) internal {
        vm.startPrank(user);
        usdc.approve(address(target), amount * USDC_SCALE / BAZAAR_SCALE);
        target.depositToInsurance(amount, pu, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    // ============================ redemptions ============================

    /// @notice Redemptions price off free capital when the inventory is whole: the seizure is
    ///         netted out, and the unrealized surplus beyond it is not paid to the leaver.
    ///         Because the reduction is applied per share rather than as a cap on one payout, the
    ///         same price holds for every redemption — the seizure survives even a full exit of
    ///         the supply, and a separate ceiling on the payout would be redundant.
    function test_sharePrice_excludesSeizureAndIgnoresGain() public {
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE);
        uint256 shares = 100 * BAZAAR_SCALE;
        vm.prank(carol);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);

        uint256 fund = _insuranceBalance();
        uint256 seized = fund / 2;
        // Entry 10k above the mark: the seizure covers that loss with ~7k to spare.
        uint256 entry = _stageNet(pair, MARK, seized, int256(seized) - 10_000 * int256(BAZAAR_SCALE));
        uint256 supply = pair.totalInsuranceShares();

        uint256 before = usdc.balanceOf(carol);
        _execute(carol);
        uint256 paid = (usdc.balanceOf(carol) - before) * 1e12;

        int256 net = _netAt(pair, entry, seized, MARK);
        assertGt(net, 0, "sanity: the inventory is whole");
        assertApproxEqRel(paid, shares * (fund - seized) / supply, 1e15, "priced on free capital");
        assertLt(paid, shares * fund / supply, "strictly below the raw-balance price");
        assertLt(paid, shares * (fund - seized + uint256(net)) / supply, "the surplus is not paid out");
    }

    /// @notice An inventory loss the fund will bear comes off the redemption basis: the leaver
    ///         carries their share of it instead of leaving it to the remaining LPs.
    function test_withdraw_subtractsLossTheFundBears() public {
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE);
        uint256 shares = 100 * BAZAAR_SCALE;
        vm.prank(carol);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);

        uint256 fund = _insuranceBalance();
        uint256 seized = fund / 2;
        uint256 entry = _stageNet(pair, MARK, seized, -5_000 * int256(BAZAAR_SCALE));
        uint256 supply = pair.totalInsuranceShares();

        uint256 before = usdc.balanceOf(carol);
        _execute(carol);
        uint256 paid = (usdc.balanceOf(carol) - before) * 1e12;

        uint256 loss = uint256(-_netAt(pair, entry, seized, MARK));
        assertApproxEqRel(paid, shares * (fund - seized - loss) / supply, 1e12, "free capital less the loss");
        assertLt(paid, shares * (fund - seized) / supply, "strictly below the free-capital price");
    }

    /// @notice Without the seizure staged, the same full exit drains the fund — so the assertions
    ///         above are the netting doing work, not the rate limit or a rounding floor.
    function test_sharePrice_noInventory_fullExitDrains() public {
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE);
        uint256 fundBefore = _insuranceBalance();
        _requestAll(carol);
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);

        _execute(carol);
        assertLt(_insuranceBalance(), fundBefore / 4, "no earmark, so the exit takes the fund");
    }

    /// @notice A fund whose every dollar is earmarked cannot price shares at all — paying zero
    ///         would confiscate stakes that still have worth once the inventory unwinds.
    function test_withdraw_fullyCommittedFund_reverts() public {
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE);
        _requestAll(carol);
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);

        _stageHeldInventory(60_000 * BAZAAR_SCALE, _insuranceBalance());

        bytes[] memory pu = _freshPrice();
        vm.prank(carol);
        vm.expectRevert(InsuranceVaultLib.InsuranceVaultLib__FundCommittedToInventory.selector);
        pair.executeInsuranceWithdrawal(pu, 0, 0, 0, "", "");
        assertGt(pair.insuranceShares(carol), 0, "shares retained when pricing is blocked");
    }

    // ============================ deposits, fresh mark ============================

    /// @notice A deposit pays for the inventory's unrealized surplus: the basis is free capital
    ///         plus the net position, so the pending recovery cannot be bought at a discount.
    function test_deposit_paysForInventoryGain() public {
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE);
        uint256 fund = _insuranceBalance();
        uint256 supply = pair.totalInsuranceShares();
        uint256 seized = fund / 2;
        uint256 entry = _stageNet(pair, MARK, seized, int256(seized) - 10_000 * int256(BAZAAR_SCALE));

        uint256 amount = 1_000 * BAZAAR_SCALE;
        _depositInsurance(dave, amount);
        uint256 minted = pair.insuranceShares(dave);

        uint256 basis = fund - seized + uint256(_netAt(pair, entry, seized, MARK));
        assertApproxEqRel(minted, amount * supply / basis, 1e12, "priced on free capital plus the surplus");
        assertLt(minted, amount * supply / (fund - seized), "fewer shares than free capital alone would mint");
    }

    /// @notice A deposit on a fresh mark takes the loss the fund will bear off its basis: the
    ///         newcomer does not pay for a loss the incumbents underwrote, and their shares are
    ///         worth what they paid once the loss lands.
    function test_deposit_freshMark_subtractsLossTheFundBears() public {
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE);
        uint256 fund = _insuranceBalance();
        uint256 supply = pair.totalInsuranceShares();
        uint256 seized = fund / 2;
        uint256 entry = _stageNet(pair, MARK, seized, -5_000 * int256(BAZAAR_SCALE));

        uint256 amount = 1_000 * BAZAAR_SCALE;
        _depositInsurance(dave, amount);
        uint256 minted = pair.insuranceShares(dave);

        uint256 loss = uint256(-_netAt(pair, entry, seized, MARK));
        uint256 basis = fund - seized - loss;
        assertApproxEqRel(minted, amount * supply / basis, 1e12, "priced on free capital less the loss");
        assertGt(minted, amount * supply / (fund - seized), "more shares than free capital alone would mint");
        // Once the loss lands the newcomer's shares are worth their deposit: they own
        // minted / (supply + minted) of a fund worth basis + amount.
        assertApproxEqRel(minted * (basis + amount) / (supply + minted), amount, 1e12, "whole after the loss");
    }

    /// @notice A loss past free capital above the reserve is the state a health check at this mark
    ///         opens an ADL window on, where the auction closes the inventory at the estates'
    ///         bankruptcy price and the winners take the rest. The deposit is refused there rather
    ///         than priced, since capital arriving first would shrink that auction or cancel it.
    function test_deposit_freshMark_lossPastHeadroom_refused() public {
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE);
        uint256 fund = _insuranceBalance();
        uint256 seized = fund / 2;
        _setTargetInsuranceRatioBp(pair, 1_000); // 10% target: the reserve on one unit at the mark is 1% of it
        // A loss far beyond free capital above the reserve.
        _stageNet(pair, MARK, seized, -30_000 * int256(BAZAAR_SCALE));

        uint256 reserve = _reserveAt(MARK, _cachedTargetBp());
        assertGt(reserve, 0, "sanity: a reserve exists");
        assertLt(reserve, fund - seized, "sanity: the reserve sits inside free capital");
        assertGt(30_000 * BAZAAR_SCALE, fund - seized - reserve, "sanity: the loss exceeds free capital above it");

        uint256 amount = 1_000 * BAZAAR_SCALE;
        bytes[] memory pu = _freshPrice();
        vm.startPrank(dave);
        usdc.approve(address(pair), amount * USDC_SCALE / BAZAAR_SCALE);
        vm.expectRevert(InsuranceVaultLib.InsuranceVaultLib__AdlBlocking.selector);
        pair.depositToInsurance(amount, pu, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    // ============================ deposits, price handling ============================

    /// @notice With no inventory held the basis is free capital and no mark is read: an empty
    ///         price update works even when the pair's cached price has long aged out.
    function test_deposit_noInventory_needsNoPrice() public {
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE);
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);
        uint256 fund = _insuranceBalance();
        uint256 supply = pair.totalInsuranceShares();

        uint256 amount = 1_000 * BAZAAR_SCALE;
        _depositWith(pair, dave, amount, new bytes[](0));
        assertEq(pair.insuranceShares(dave), amount * supply / fund, "priced on free capital, no oracle read");
    }

    /// @notice While the vault holds inventory a deposit resolves a price like every other priced
    ///         entry point: on a continuously traded pair with an aged cache and no update it
    ///         reverts rather than price the inventory blind.
    function test_deposit_heldInventory_continuousPair_requiresPrice() public {
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE);
        _stageHeldInventory(60_000 * BAZAAR_SCALE, _insuranceBalance() / 2);
        vm.warp(vm.getBlockTimestamp() + 4);

        vm.startPrank(dave);
        usdc.approve(address(pair), 1_000 * USDC_SCALE);
        vm.expectRevert(BazaarPair.BazaarPair__NoPriceUpdatesProvided.selector);
        pair.depositToInsurance(1_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @dev Store a fresh AAPL mark on the session pair so its stale fallback has a price.
    function _warmAapl() internal {
        bytes[] memory warm = _priceUpdateFor(AAPL_USD_FEED_ID, 150, uint64(vm.getBlockTimestamp()));
        vm.deal(address(this), 1 ether);
        mockPyth.updatePriceFeeds{value: mockPyth.getUpdateFee(warm)}(warm);
        aaplPair.refreshPrice(new bytes[](0));
    }

    /// @notice On a closed venue a deposit that would have to price held inventory refuses the
    ///         frozen mark, exactly as a redemption does: off-chain venues print the reopen hours
    ///         before the oracle can, so a depositor who can see it would buy the inventory's
    ///         recovery from the incumbents. The same deposit clears on the first fresh print,
    ///         priced with the loss the fund bears.
    function test_deposit_staleMark_heldInventory_reverts() public {
        _warmAapl();
        _depositWith(aaplPair, carol, 1_000 * BAZAAR_SCALE, new bytes[](0));
        uint256 seized = 200 * BAZAAR_SCALE;
        uint256 entry = _stageNet(aaplPair, AAPL_MARK, seized, -50 * int256(BAZAAR_SCALE));
        // Ages the cache past MAX_PRICE_STALENESS: empty calldata now resolves the stale fallback.
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);

        uint256 amount = 500 * BAZAAR_SCALE;
        vm.startPrank(dave);
        usdc.approve(address(aaplPair), amount * USDC_SCALE / BAZAAR_SCALE);
        vm.expectRevert(BazaarPair.BazaarPair__InsuranceDepositRequiresFreshPrice.selector);
        aaplPair.depositToInsurance(amount, new bytes[](0), 0, 0, 0, "", "");
        vm.stopPrank();
        assertEq(aaplPair.insuranceShares(dave), 0, "no shares minted against the frozen mark");

        // The reopen: the same deposit clears, priced on free capital less the loss the fund bears.
        uint256 fund = _fundOf(aaplPair);
        uint256 supply = aaplPair.totalInsuranceShares();
        bytes[] memory fresh = _priceUpdateFor(AAPL_USD_FEED_ID, 150, uint64(vm.getBlockTimestamp()));
        _depositWith(aaplPair, dave, amount, fresh);
        uint256 loss = uint256(-_netAt(aaplPair, entry, seized, AAPL_MARK));
        assertApproxEqRel(
            aaplPair.insuranceShares(dave), amount * supply / (fund - seized - loss), 1e12, "fresh: the loss comes off"
        );
    }

    /// @notice An inventory surplus does not buy the depositor a way around the freshness gate
    ///         either: the direction the frozen mark happens to point is not the protocol's to
    ///         judge, since it cannot see the reopen at all.
    function test_deposit_staleMark_heldProfitableInventory_reverts() public {
        _warmAapl();
        _depositWith(aaplPair, carol, 1_000 * BAZAAR_SCALE, new bytes[](0));
        // Long from 250 with 200 seized: 100 in hand beyond the seizure at the 150 mark. (The
        // staging helper needs entry >= seized to place the bankruptcy notional.)
        _stageNet(aaplPair, AAPL_MARK, 200 * BAZAAR_SCALE, 100 * int256(BAZAAR_SCALE));
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);

        vm.startPrank(dave);
        usdc.approve(address(aaplPair), 500 * USDC_SCALE);
        vm.expectRevert(BazaarPair.BazaarPair__InsuranceDepositRequiresFreshPrice.selector);
        aaplPair.depositToInsurance(500 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @notice The gate is scoped to held inventory, not to market hours: with the vault flat, a
    ///         deposit into a closed-venue pair reads no mark and clears on an empty update. This
    ///         is the case that matters — recapitalizing a fund drained by ordinary bad debt is
    ///         never blocked by a shut venue.
    function test_deposit_staleMark_noInventory_clears() public {
        _warmAapl();
        _depositWith(aaplPair, carol, 1_000 * BAZAAR_SCALE, new bytes[](0));
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);

        uint256 fund = _fundOf(aaplPair);
        uint256 supply = aaplPair.totalInsuranceShares();
        uint256 amount = 500 * BAZAAR_SCALE;
        _depositWith(aaplPair, dave, amount, new bytes[](0));
        assertEq(aaplPair.insuranceShares(dave), amount * supply / fund, "priced on free capital, no oracle read");
    }
}
