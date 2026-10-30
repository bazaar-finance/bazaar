// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MatchingEngineLib} from "../../src/libraries/MatchingEngineLib.sol";
import {BazaarTradingAccount} from "../../examples/BazaarTradingAccount.sol";

/// @title TradingAccountTest
/// @notice The example contract account from the batching guide, driven against a live pair: one
///         transaction funds the account, deposits and rests several orders; a batch is atomic
///         and fails with the pair's own error; the account is the trader for every per-user
///         rule; withdrawals land in the account and are forwarded in the same batch.
contract TradingAccountTest is IntegrationBase {
    uint256 constant BTC = BAZAAR_SCALE;
    uint256 constant DEPOSIT = 20_000 * BAZAAR_SCALE;

    BazaarTradingAccount internal account;

    function setUp() public override {
        super.setUp();
        account = new BazaarTradingAccount(alice);
        // The account holds its own USDC; the owner sends some over and tops up its ETH for
        // Pyth fees.
        vm.prank(alice);
        usdc.transfer(address(account), DEPOSIT * USDC_SCALE / BAZAAR_SCALE);
        vm.deal(alice, 1 ether);
    }

    // ---------------------------- call builders ----------------------------

    function _call(address target, uint256 value, bytes memory data)
        internal
        pure
        returns (BazaarTradingAccount.Call memory c)
    {
        c.target = target;
        c.value = value;
        c.data = data;
    }

    function _approveAndDeposit() internal view returns (BazaarTradingAccount.Call[2] memory c) {
        c[0] =
            _call(address(usdc), 0, abi.encodeCall(usdc.approve, (address(pair), DEPOSIT * USDC_SCALE / BAZAAR_SCALE)));
        c[1] = _call(address(pair), 0, abi.encodeCall(pair.depositCollateral, (DEPOSIT, 0, 0, 0, "", "")));
    }

    /// @dev A createOrder call; `pu` may be empty when an earlier call in the batch stored the price.
    function _create(BazaarTypes.OrderSpec memory s, bytes[] memory pu, uint256 fee)
        internal
        view
        returns (BazaarTradingAccount.Call memory)
    {
        return _call(address(pair), fee, abi.encodeCall(pair.createOrder, (s, _hintsNone(), pu, 0, 0, 0, "", "")));
    }

    function _execute(BazaarTradingAccount.Call[] memory calls, uint256 value) internal {
        vm.prank(alice);
        account.execute{value: value}(calls);
    }

    function _activeOrders(address user) internal view returns (uint256 count) {
        (, count,,) = lens.getUserActiveLimitOrders(address(pair), user);
    }

    // ---------------------------- tests ----------------------------

    /// @notice One transaction approves, deposits and rests three orders. Only the first order
    ///         carries the Pyth update and its fee; the two after it read the price it stored.
    function test_batch_fundDepositAndRestThreeOrders() public {
        bytes[] memory pu = _freshPrice();
        uint256 fee = oracle.getUpdateFee(pu);
        BazaarTradingAccount.Call[2] memory fund = _approveAndDeposit();

        BazaarTradingAccount.Call[] memory calls = new BazaarTradingAccount.Call[](5);
        calls[0] = fund[0];
        calls[1] = fund[1];
        calls[2] = _create(_limitSpec(true, BTC / 10, 49_000 * BAZAAR_SCALE), pu, fee);
        calls[3] = _create(_limitSpec(true, BTC / 10, 48_000 * BAZAAR_SCALE), new bytes[](0), 0);
        calls[4] = _create(_limitSpec(false, BTC / 10, 52_000 * BAZAAR_SCALE), new bytes[](0), 0);
        _execute(calls, fee);

        assertEq(_posCollateral(address(account)), DEPOSIT, "the deposit sits in the account's bucket");
        assertEq(_activeOrders(address(account)), 3, "three orders rest for the account");
        assertEq(_activeOrders(alice), 0, "none for the owner's own address");
        assertEq(_posSize(address(account)), 0, "nothing crossed");
        _assertBooks("after the batch");
    }

    /// @notice ETH the pair does not spend on the Pyth update comes back to the account, and a
    ///         later batch can send it on to the owner.
    function test_batch_unusedEthIsRefundedToTheAccount() public {
        bytes[] memory pu = _freshPrice();
        uint256 fee = oracle.getUpdateFee(pu);
        BazaarTradingAccount.Call[2] memory fund = _approveAndDeposit();
        BazaarTradingAccount.Call[] memory calls = new BazaarTradingAccount.Call[](3);
        calls[0] = fund[0];
        calls[1] = fund[1];
        calls[2] = _create(_limitSpec(true, BTC / 10, 49_000 * BAZAAR_SCALE), pu, fee + 0.01 ether);
        _execute(calls, fee + 0.01 ether);
        assertEq(address(account).balance, 0.01 ether, "the refund landed in the account");

        BazaarTradingAccount.Call[] memory sweep = new BazaarTradingAccount.Call[](1);
        sweep[0] = _call(alice, 0.01 ether, "");
        uint256 before = alice.balance;
        _execute(sweep, 0);
        assertEq(alice.balance, before + 0.01 ether, "and was forwarded to the owner");
    }

    /// @notice The account is one trader: a bid and an ask from it that cross each other do not
    ///         fill. The later order is cancelled as a self-match and the earlier one keeps resting.
    function test_batch_ownOrdersThatCrossCancelTheLaterOne() public {
        bytes[] memory pu = _freshPrice();
        uint256 fee = oracle.getUpdateFee(pu);
        BazaarTradingAccount.Call[2] memory fund = _approveAndDeposit();
        BazaarTradingAccount.Call[] memory calls = new BazaarTradingAccount.Call[](4);
        calls[0] = fund[0];
        calls[1] = fund[1];
        calls[2] = _create(_limitSpec(true, BTC / 10, 50_000 * BAZAAR_SCALE), pu, fee);
        calls[3] = _create(_limitSpec(false, BTC / 10, 50_000 * BAZAAR_SCALE), new bytes[](0), 0);
        _execute(calls, fee);

        assertEq(_posSize(address(account)), 0, "no fill against itself");
        assertEq(_activeOrders(address(account)), 1, "the bid rests, the ask was cancelled");
    }

    /// @notice A batch is atomic: a fill-or-kill that cannot fill reverts the whole batch with the
    ///         pair's own error, and the orders before it are not left behind.
    function test_batch_revertsWholeWithThePairsError() public {
        bytes[] memory pu = _freshPrice();
        uint256 fee = oracle.getUpdateFee(pu);
        BazaarTradingAccount.Call[2] memory fund = _approveAndDeposit();
        BazaarTypes.OrderSpec memory fok = _limitSpec(true, BTC / 10, 50_000 * BAZAAR_SCALE);
        fok.tif = BazaarTypes.TimeInForce.FOK;

        BazaarTradingAccount.Call[] memory calls = new BazaarTradingAccount.Call[](4);
        calls[0] = fund[0];
        calls[1] = fund[1];
        calls[2] = _create(_limitSpec(true, BTC / 10, 49_000 * BAZAAR_SCALE), pu, fee);
        calls[3] = _create(fok, new bytes[](0), 0);

        // The fill-or-kill is the account's second order, so it is order 2 and nothing of it fills.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MatchingEngineLib.MatchingEngineLib__FillOrKillUnfilled.selector, 2, BTC / 10)
        );
        account.execute{value: fee}(calls);

        assertEq(_activeOrders(address(account)), 0, "the earlier order did not survive the revert");
        assertEq(_posCollateral(address(account)), 0, "nor the deposit");
    }

    /// @notice Only the owner can direct the account.
    function test_batch_onlyOwner() public {
        BazaarTradingAccount.Call[] memory calls = new BazaarTradingAccount.Call[](1);
        calls[0] = _call(address(usdc), 0, abi.encodeCall(usdc.approve, (address(pair), 1)));
        vm.prank(bob);
        vm.expectRevert(BazaarTradingAccount.BazaarTradingAccount__NotOwner.selector);
        account.execute(calls);
    }

    /// @notice A withdrawal pays the account, since the account is the trader; the same batch
    ///         forwards the USDC to the owner.
    function test_batch_withdrawalLandsInTheAccountAndIsForwarded() public {
        BazaarTradingAccount.Call[2] memory fund = _approveAndDeposit();
        BazaarTradingAccount.Call[] memory calls = new BazaarTradingAccount.Call[](2);
        calls[0] = fund[0];
        calls[1] = fund[1];
        _execute(calls, 0);

        bytes[] memory pu = _freshPrice();
        uint256 fee = oracle.getUpdateFee(pu);
        uint256 usdcAmount = DEPOSIT * USDC_SCALE / BAZAAR_SCALE;
        BazaarTradingAccount.Call[] memory exit = new BazaarTradingAccount.Call[](2);
        exit[0] = _call(address(pair), fee, abi.encodeCall(pair.withdrawCollateral, (DEPOSIT, pu, 0, 0, 0, "")));
        exit[1] = _call(address(usdc), 0, abi.encodeCall(usdc.transfer, (alice, usdcAmount)));
        uint256 before = usdc.balanceOf(alice);
        _execute(exit, fee);

        assertEq(usdc.balanceOf(alice), before + usdcAmount, "the owner has the USDC back");
        assertEq(_posCollateral(address(account)), 0, "the account's bucket is empty");
    }

    /// @notice Gas: four resting orders sent as four direct calls against the same four through
    ///         one batch. Run with and without `--isolate` to see the difference between four
    ///         transactions and one; these are `emit log_named_uint` readings, not assertions.
    function test_gas_fourOrders_directVersusBatched() public {
        _deposit(alice, DEPOSIT);
        bytes[] memory pu = _freshPrice();
        uint256 fee = oracle.getUpdateFee(pu);
        vm.deal(alice, 1 ether);
        BazaarTypes.OrderSpec[4] memory specs = [
            _limitSpec(true, BTC / 10, 49_000 * BAZAAR_SCALE),
            _limitSpec(true, BTC / 10, 48_000 * BAZAAR_SCALE),
            _limitSpec(false, BTC / 10, 51_000 * BAZAAR_SCALE),
            _limitSpec(false, BTC / 10, 52_000 * BAZAAR_SCALE)
        ];

        uint256 direct;
        for (uint256 i = 0; i < 4; ++i) {
            bytes[] memory carried = i == 0 ? pu : new bytes[](0);
            vm.prank(alice);
            uint256 g0 = gasleft();
            pair.createOrder{value: i == 0 ? fee : 0}(specs[i], _hintsNone(), carried, 0, 0, 0, "", "");
            direct += g0 - gasleft();
        }
        emit log_named_uint("four resting orders, four direct calls", direct);

        BazaarTradingAccount.Call[2] memory fund = _approveAndDeposit();
        BazaarTradingAccount.Call[] memory calls = new BazaarTradingAccount.Call[](6);
        calls[0] = fund[0];
        calls[1] = fund[1];
        for (uint256 i = 0; i < 4; ++i) {
            calls[2 + i] = _create(specs[i], i == 0 ? pu : new bytes[](0), i == 0 ? fee : 0);
        }
        vm.prank(alice);
        uint256 g1 = gasleft();
        account.execute{value: fee}(calls);
        uint256 batched = g1 - gasleft();
        emit log_named_uint("approve + deposit + four resting orders, one batch", batched);
    }
}
