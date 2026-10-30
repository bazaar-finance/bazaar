// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {IntegrationBase} from "./IntegrationBase.sol";

/// @title AdlWindowReleaseTest
/// @notice The deferred-liquidation list lives only as long as the ADL window it was recorded for.
///         Whatever leaves no window open — the health check after an auction batch, any other
///         health check that finds the fund recovered, or the one that follows a liquidation whose
///         inline unload sold the inventory the account was deferred against — empties the list,
///         and an account it left open is an ordinary liquidation candidate again.
contract AdlWindowReleaseTest is IntegrationBase {
    uint256 constant ESTATE_SIZE = 72 * BAZAAR_SCALE / 100;
    uint256 constant DEFERRED_SIZE = 88 * BAZAAR_SCALE / 100;

    // ---------------------------- fixture ----------------------------

    /// @dev dave long and bob short 0.72 at $80k; alice short and carol long 0.88 at $30k. Nobody
    ///      is seized.
    function _openBothPairs() internal {
        _deposit(dave, 19_200 * BAZAAR_SCALE);
        _deposit(bob, 16_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, true, ESTATE_SIZE, 80_000 * BAZAAR_SCALE, 80_000);
        _roll(2);
        _placeLimitAt(bob, false, ESTATE_SIZE, 80_000 * BAZAAR_SCALE, 80_000);
        assertEq(_posSize(bob), ESTATE_SIZE, "fixture: dave and bob crossed");

        _deposit(alice, 13_200 * BAZAAR_SCALE);
        _deposit(carol, 13_200 * BAZAAR_SCALE);
        _placeLimitAt(carol, true, DEFERRED_SIZE, 30_000 * BAZAAR_SCALE, 30_000);
        _roll(2);
        _placeLimitAt(alice, false, DEFERRED_SIZE, 30_000 * BAZAAR_SCALE, 30_000);
        assertEq(_posSize(alice), DEFERRED_SIZE, "fixture: alice and carol crossed");
    }

    /// @dev Opens a window and defers alice inside it. Seizing dave at $30k hands the vault a 0.72
    ///      long whose $36,000 loss is far past his $19,200 and the seed, so the window opens; the
    ///      $30k pair is opened first because the window freezes matching. At $43k alice is below
    ///      maintenance but not under water, and netting her against the vault's long would
    ///      realize the $50k entry gap on 0.72 — past the two slices' seizure plus the fund's free
    ///      capital — so she is left open and listed.
    function _deferAliceInsideWindow() internal {
        _openBothPairs();

        assertEq(_liquidateAt(dave, 30_000), 1, "fixture: dave seized");
        assertTrue(pair.isAdlPending(), "fixture: the estate's loss exceeds the fund");

        assertEq(_liquidateAt(alice, 43_000), 0, "fixture: alice deferred, not seized");
        assertEq(pair.auxState().deferredCount, 1, "fixture: one deferred liquidation");
        assertEq(pair.deferredLiquidations(0), alice, "fixture: alice is listed");
        assertEq(_posSize(alice), DEFERRED_SIZE, "fixture: her position is left open");
        assertTrue(pair.isAdlPending(), "fixture: the window stays open");
    }

    /// @dev Liquidate one account as the keeper, at a fresh price four seconds on.
    function _liquidateAt(address user, uint256 priceUsd) internal returns (uint256) {
        return _liquidateAt(_arr1(user), priceUsd);
    }

    function _liquidateAt(address[] memory users, uint256 priceUsd) internal returns (uint256) {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceAt(priceUsd);
        vm.prank(seq);
        return pair.liquidate(users, pu);
    }

    /// @dev Seizes dave and defers alice in one call at $55k, with whatever rests in the book for
    ///      the call's inline unload to sell the vault's long into. At $55k dave keeps $1,200 of
    ///      his $19,200, so the 0.72 long the vault inherits carries no loss beyond its seizure and
    ///      opens no window of its own. alice is $8,800 past bankruptcy; netting 0.72 of her
    ///      against the long would realize the $50k entry gap, $36,000, against the two slices'
    ///      seizure of $30,000 plus the fund above its reserve, which is at most the $4,000 seed,
    ///      so she is left open and listed, and her loss beyond collateral is what a window would
    ///      be held open for. The deferral is observed through what liquidate does not do: it
    ///      returns one seizure, and her position is untouched.
    function _seizeDaveDeferAlice() internal {
        address[] memory users = new address[](2);
        users[0] = dave;
        users[1] = alice;
        assertEq(_liquidateAt(users, 55_000), 1, "dave seized, alice not");
        assertEq(_posSize(dave), 0, "dave is closed");
        assertEq(_posSize(alice), DEFERRED_SIZE, "alice is left open");
    }

    function _pendingLiqSize() internal view returns (uint256 size) {
        (,,,,,, size,,,,,,,,,,) = pair.pairVault();
    }

    // ---------------------------- tests ----------------------------

    /// @notice A batch that restores the fund resolves the window with alice still open and
    ///         listed: the deferred pass has no cohort to close her against and still cannot afford
    ///         to net her, and the inventory leg closes only as much of the vault's long against bob
    ///         as the fund needs, so inventory remains and the list is not consumed by seizing its
    ///         accounts as the new inventory. The window's resolution empties the list.
    function test_windowResolvedByBatch_emptiesTheList() public {
        _deferAliceInsideWindow();

        // Past the Dutch decay, so bob's score clears the threshold.
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.ADL_AUCTION_DURATION + 1);
        bytes[] memory pu = _priceAt(43_000);
        vm.prank(seq);
        pair.executeAdl(_arr1(bob), new address[](0), pu);

        assertFalse(pair.isAdlPending(), "the batch resolved the window");
        assertGt(_pendingLiqSize(), 0, "inventory remains, so no deferred account was seized as inventory");
        assertLt(_posSize(bob), ESTATE_SIZE, "bob took part of the close");
        assertEq(_posSize(alice), DEFERRED_SIZE, "alice is untouched and still open");
        assertEq(pair.auxState().deferredCount, 0, "the list is emptied with the window");
        _assertBooks("after the batch");
    }

    /// @notice A window resolved by something other than a batch empties the list too. Capital
    ///         credited through the terminator, the route a forfeited insurer-termination bond
    ///         takes, judges no vault health, so the window and the list survive it; the next
    ///         refresh finds the fund able to finish the inventory inside the band and alice not
    ///         under water, and resolves the window with no batch having run. Delisted, alice is
    ///         an ordinary liquidation candidate: the recovered fund can now afford the netting
    ///         she was deferred from, and the next liquidation that names her seizes her.
    function test_windowResolvedByRefresh_emptiesTheList_accountLiquidatesNormally() public {
        _deferAliceInsideWindow();

        // An insurance deposit is refused while the window is pending, so the capital arrives as
        // a credit: USDC moved to the pair, then booked into the fund by the terminator.
        vm.prank(deployer);
        usdc.transfer(address(pair), 20_000 * USDC_SCALE);
        vm.prank(pair.umaContract());
        pair.creditInsurance(20_000 * BAZAAR_SCALE);
        assertTrue(pair.isAdlPending(), "a credit does not judge vault health");
        assertEq(pair.auxState().deferredCount, 1, "and leaves the list alone");

        vm.warp(vm.getBlockTimestamp() + 30);
        bytes[] memory pu = _priceAt(43_000);
        vm.prank(seq);
        pair.refreshPrice(pu);

        assertFalse(pair.isAdlPending(), "the refresh resolved the window");
        assertEq(pair.auxState().deferredCount, 0, "the list is emptied with the window");
        assertEq(_posSize(alice), DEFERRED_SIZE, "alice is still open");

        assertEq(_liquidateAt(alice, 43_000), 1, "an ordinary liquidation seizes her");
        assertEq(_posSize(alice), 0, "alice is closed");
        assertEq(pair.auxState().deferredCount, 0, "and not listed again");
        _assertBooks("after the liquidation");
    }

    /// @notice A liquidation that defers an account and then sells the inventory it was deferred
    ///         against in its own inline unload reaches the health check with nothing to hold a
    ///         window open — no inventory, so no exposure and no netting to defer — and the list
    ///         is emptied just as a released window empties it. erin's bid, one unload band under
    ///         the $55k oracle and above the long's $53,333 bankruptcy price, takes the whole long
    ///         at no cost to the fund. alice, still open and still bankrupt, is an ordinary
    ///         liquidation candidate: with no inventory to net against, the next liquidation that
    ///         names her seizes her outright.
    function test_walkSellsTheInventory_noWindow_emptiesTheList() public {
        _openBothPairs();

        address erin = makeAddr("erin");
        usdc.mint(erin, INITIAL_USER_BALANCE);
        _deposit(erin, 12_000 * BAZAAR_SCALE);
        _placeLimitAt(erin, true, ESTATE_SIZE, 54_000 * BAZAAR_SCALE, 55_000);
        assertEq(_posSize(erin), 0, "fixture: erin's bid rests");

        _seizeDaveDeferAlice();

        assertEq(_pendingLiqSize(), 0, "the inline unload sold the whole long");
        assertEq(_posSize(erin), ESTATE_SIZE, "to erin");
        assertFalse(pair.isAdlPending(), "nothing is left to hold a window open");
        assertEq(pair.auxState().deferredCount, 0, "so alice is not listed for one");
        _assertBooks("after the liquidation");

        assertEq(_liquidateAt(alice, 55_000), 1, "an ordinary liquidation seizes her");
        assertEq(_posSize(alice), 0, "alice is closed");
        assertEq(pair.auxState().deferredCount, 0, "and not listed");
        _assertBooks("after her seizure");
    }

    /// @notice Control for the test above: the same liquidation with nothing resting to sell into
    ///         keeps the long, and the health check finds alice's loss beyond collateral opposite
    ///         it, opens the window that resolves her, and keeps her listed for its auction. The
    ///         inventory itself is covered, so the window is held open for her alone.
    function test_walkSellsNothing_windowOpens_keepsTheList() public {
        _openBothPairs();

        _seizeDaveDeferAlice();

        assertEq(_pendingLiqSize(), ESTATE_SIZE, "the long is still held");
        assertTrue(pair.isAdlPending(), "alice's loss beyond collateral opens the window");
        assertEq(pair.auxState().deferredCount, 1, "she is listed for its auction");
        assertEq(pair.deferredLiquidations(0), alice, "by name");
        _assertBooks("after the liquidation");
    }

    // ------------------ a batch against an inventory under water ------------------

    /// @notice The window alice holds open, run at $50k: the long the vault inherited from dave
    ///         is now under water against its $53,333 bankruptcy price, and alice's 0.88 outnumbers
    ///         it, so no netting can leave inventory behind and bob, the only winner opposite it, is
    ///         closed against the whole long. Only the part the fund cannot carry settles at the
    ///         bankruptcy price; the rest closes at the $50k mark, the fund paying the distance. alice
    ///         is then seized as the new inventory, and the health check after the batch aims any
    ///         window it keeps open at her counterparties.
    function test_underWaterBatch_closesPastTheFundsShareAtTheMark() public {
        _openBothPairs();
        _seizeDaveDeferAlice();
        assertTrue(pair.isAdlPending(), "fixture: alice holds the window open");
        uint256 bankruptcyPrice = _inventoryBankruptcyPrice();
        assertGt(bankruptcyPrice, 50_000 * BAZAAR_SCALE, "fixture: the long is under water at $50k");

        // Past the Dutch decay, so bob's score clears the threshold.
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.ADL_AUCTION_DURATION + 1);
        bytes[] memory pu = _priceAt(50_000);
        vm.recordLogs();
        vm.prank(seq);
        pair.executeAdl(_arr1(bob), new address[](0), pu);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 atBankruptcy, uint256 atMark) = _closesOf(logs, bob, bankruptcyPrice, 50_000 * BAZAAR_SCALE);
        assertEq(atBankruptcy + atMark, ESTATE_SIZE, "bob took the whole long");
        assertGt(atMark, 0, "the part past the fund's share closed at the mark");
        assertEq(_posSize(bob), 0, "bob is closed");
        assertEq(_pendingLiqSize(), DEFERRED_SIZE, "alice is the inventory now");
        assertEq(_posSize(alice), 0, "her position went with it");
        assertEq(_deficitOf(), 0, "nothing went unpaid");
        if (pair.isAdlPending()) assertTrue(pair.auxState().adlLongs, "a window left open targets the longs");
        _assertBooks("after the batch");
    }

    /// @dev The vault inventory's average bankruptcy price, rounded up as a long's is.
    function _inventoryBankruptcyPrice() internal view returns (uint256) {
        (,,,,,, uint256 size,, uint256 bankruptcyNotional,,,,,,,,) = pair.pairVault();
        return (bankruptcyNotional * BAZAAR_SCALE + size - 1) / size;
    }

    function _deficitOf() internal view returns (uint256 d) {
        (,,,,,,,,,,, d,,,,,) = pair.pairVault();
    }

    /// @dev The sizes `user`'s UserAdld closes settled at `bankruptcyPrice` and at `mark`, checking
    ///      that every close settled at one of the two and that the ones at the mark came last.
    function _closesOf(Vm.Log[] memory logs, address user, uint256 bankruptcyPrice, uint256 mark)
        internal
        view
        returns (uint256 atBankruptcy, uint256 atMark)
    {
        bytes32 sig = keccak256("UserAdld(bytes32,address,bool,uint256,int256,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(pair) || logs[i].topics[0] != sig) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != user) continue;
            (, uint256 size,,,, uint256 price,) =
                abi.decode(logs[i].data, (bool, uint256, int256, uint256, uint256, uint256, uint256));
            if (price == mark) {
                atMark += size;
            } else {
                assertEq(price, bankruptcyPrice, "a close settles at the bankruptcy price or the mark");
                assertEq(atMark, 0, "the bankruptcy-priced part comes first");
                atBankruptcy += size;
            }
        }
    }
}
