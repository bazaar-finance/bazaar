// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";

/// @notice A relayed createOrder / cancelOrders fee is paid from the signer's WALLET, never from
///         bucket collateral. Collateral backs an open position and leaves only through
///         withdrawCollateral and its gates; a fee debited from the bucket would be a second exit
///         that skips them all, and a user relaying their own signed call would turn it into a
///         collateral-to-wallet pump — createOrder(TakeProfit) + cancelOrders([tpId]) at up to $1
///         each, repeatable regardless of margin, because trigger orders skip the margin gate.
///
///         The cases below pin both halves. The bucket and the principal ledger D never move on a
///         relayed create or cancel, whatever the bucket's health; when the wallet cannot pay, the
///         call reverts rather than reaching for collateral; and, because nothing in the vault
///         moves, a relayed cancel stays available in every lifecycle state a self-submitted
///         cancel is.
contract CancelOrdersRelayerFeeGuardsTest is IntegrationBase {
    struct CancelReq {
        uint256 nonce;
        uint256 deadline;
        uint256 fee;
        bytes sig;
    }

    struct CreateReq {
        BazaarTypes.OrderSpec spec;
        uint256 nonce;
        uint256 deadline;
        uint256 fee;
        bytes sig;
    }

    function _sign(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(pair.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Build the signed request WITHOUT submitting it. Split from submission because the
    ///      build reads metaTxNonces and DOMAIN_SEPARATOR — external calls that would swallow a
    ///      preceding vm.expectRevert. Every caller must expectRevert immediately before the
    ///      cancelOrders call itself, never before this.
    function _buildRelayedCancel(address user, uint256 pk, uint256[] memory ids) internal returns (CancelReq memory r) {
        r.nonce = pair.metaTxNonces(user);
        r.deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        r.fee = MetaTxLib.MAX_RELAYER_FEE;
        bytes32 structHash = keccak256(
            abi.encode(MetaTxLib.CANCEL_ORDERS_TYPEHASH, keccak256(abi.encodePacked(ids)), r.nonce, r.deadline, r.fee)
        );
        r.sig = _sign(pk, structHash);
    }

    /// @dev A signed take-profit closing a long at `triggerPrice`. Trigger orders skip the margin
    ///      gate at creation, which is what makes them the repeatable action of the pump.
    function _buildRelayedTakeProfit(address user, uint256 pk, uint256 size, uint256 triggerPrice)
        internal
        returns (CreateReq memory r)
    {
        r.spec.orderType = BazaarTypes.OrderType.TakeProfit;
        r.spec.isLong = false; // closes a long
        r.spec.size = size;
        r.spec.triggerPrice = triggerPrice;
        r.spec.maxSlippageBp = 100;
        r.nonce = pair.metaTxNonces(user);
        r.deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        r.fee = MetaTxLib.MAX_RELAYER_FEE;
        bytes32 structHash = keccak256(
            abi.encode(
                MetaTxLib.CREATE_ORDER_TYPEHASH,
                r.spec.orderType,
                r.spec.triggerPrice,
                r.spec.limitPrice,
                r.spec.maxSlippageBp,
                r.spec.size,
                r.spec.isLong,
                r.spec.isPostOnly,
                r.spec.tif,
                r.spec.expirationBlock,
                r.spec.integrator,
                r.nonce,
                r.deadline,
                r.fee
            )
        );
        r.sig = _sign(pk, structHash);
    }

    /// @dev An ERC-2612 permit for `value` USDC in favour of the pair, encoded the way
    ///      BazaarPair._executePermit decodes it.
    function _signPermit(address owner, uint256 pk, uint256 value, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash =
            keccak256(abi.encode(permitTypehash, owner, address(pair), value, usdc.nonces(owner), deadline));
        bytes32 digest = MessageHashUtils.toTypedDataHash(usdc.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encode(value, deadline, v, r, s);
    }

    /// @dev A second address controlled by the same actor — what makes the relayer fee a
    ///      self-payment rather than payment for a genuine relaying service.
    function _actor(string memory label) internal returns (address user, uint256 pk, address relayerEoa) {
        (user, pk) = makeAddrAndKey(label);
        relayerEoa = makeAddr(string.concat(label, "SecondEOA"));
        usdc.mint(user, 200_000 * USDC_SCALE);
    }

    /// @dev _deposit approves exactly the deposit, so a relayed fee needs its own allowance.
    function _allowFees(address user) internal {
        vm.prank(user);
        usdc.approve(address(pair), type(uint256).max);
    }

    /// @dev MAX_RELAYER_FEE in native USDC (1e6) precision.
    function _usdcFee() internal pure returns (uint256) {
        return MetaTxLib.MAX_RELAYER_FEE / 1e12;
    }

    /// @dev Drive the pair into a REAL ADL window (isAdlPending is packed with the pair's other
    ///      lifecycle flags, so there is no stdstore shortcut): liquidate a deep-underwater
    ///      phantom long whose vault-inherited loss (~$4,950 at the $50k mark) exceeds the ADL
    ///      trigger share of the ~$5k genesis insurance fund. Any order a test needs must
    ///      already exist — order creation is frozen once ADL is pending — and must rest on the
    ///      ASK side: liquidate crosses the inherited long into resting bids before judging
    ///      vault health, so a resting bid would be filled by that unload instead of surviving
    ///      to the cancel under test.
    function _triggerRealAdl() internal {
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        _deposit(bob, 60_000 * BAZAAR_SCALE);
        uint256 size = 5 * BAZAAR_SCALE;
        _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE); // crosses alice's resting bid on arrival
        assertEq(_posSize(alice), size, "position opened");

        _deposit(dave, 10 * BAZAAR_SCALE);
        _writePosition(dave, true, size, 254_960 * BAZAAR_SCALE);
        bytes[] memory liqPu = _freshPrice();
        vm.prank(makeAddr("adlLiquidator"));
        pair.liquidate(_arr1(dave), liqPu);
        assertTrue(pair.isAdlPending(), "ADL window is live");
    }

    // ─────────────────────────── the empty-list no-op ───────────────────────────

    /// @notice An empty id list is rejected outright: with no order consumed the call is a
    ///         no-op that would still consume the signer's nonce and pay the relayer.
    function test_relayedCancel_emptyList_reverts() public {
        (address user, uint256 pk, address relayerEoa) = _actor("emptyList");
        _deposit(user, 10 * BAZAAR_SCALE);
        _allowFees(user);

        uint256[] memory ids = _empty();
        CancelReq memory r = _buildRelayedCancel(user, pk, ids);

        vm.prank(relayerEoa);
        vm.expectRevert(BazaarPair.BazaarPair__ExceedsMaxCancelsPerCall.selector);
        pair.cancelOrders(ids, r.nonce, r.deadline, r.fee, r.sig, "");

        assertEq(_escrowOwed(relayerEoa), 0, "no fee accrued");
        assertEq(pair.metaTxNonces(user), 0, "nonce not consumed");
    }

    // ───────────── the pump: take-profit create + cancel on an underwater position ─────────────

    /// @notice The sanctioned exit refuses an underwater position even $1, so the relayed
    ///         create/cancel pair must not become the exit instead. Self-relayed round trips
    ///         leave the bucket and D exactly where they were; the fees move wallet to escrow.
    function test_relayedTpRoundTrips_onUnderwaterPosition_neverTouchCollateral() public {
        (address user, uint256 pk, address relayerEoa) = _actor("pump");
        _deposit(user, 10 * BAZAAR_SCALE);
        _allowFees(user);
        // 0.1 BTC long entered at $50,050 notional -> underwater at $50k spot
        uint256 size = BAZAAR_SCALE / 10;
        _writePosition(user, true, size, 5_005 * BAZAAR_SCALE);

        // The sanctioned exit path refuses even $1 — the margin check holds the collateral.
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        vm.expectRevert();
        pair.withdrawCollateral(1 * BAZAAR_SCALE, pu, 0, 0, 0, "");

        uint256 dBefore = _totalDeposited();
        uint256 walletBefore = usdc.balanceOf(user);

        // Trigger above spot ($60k vs $50k): the take-profit rests untriggered outside the book,
        // so each round trip is pure create + cancel with no fill in between.
        uint256 rounds = 3;
        for (uint256 i; i < rounds; ++i) {
            CreateReq memory c = _buildRelayedTakeProfit(user, pk, size, 60_000 * BAZAAR_SCALE);
            pu = _freshPrice();
            vm.prank(relayerEoa);
            pair.createOrder(c.spec, _hintsNone(), pu, c.nonce, c.deadline, c.fee, c.sig, "");
            uint256 tpId = _lastCreatedOrderId(pair);

            uint256[] memory ids = _one(tpId);
            CancelReq memory r = _buildRelayedCancel(user, pk, ids);
            vm.prank(relayerEoa);
            pair.cancelOrders(ids, r.nonce, r.deadline, r.fee, r.sig, "");
            assertGt(_canceledBlock(tpId), 0, "round trip completed");
        }

        assertEq(_posCollateral(user), 10 * BAZAAR_SCALE, "margin still backing the position");
        assertEq(_totalDeposited(), dBefore, "D untouched");
        assertEq(_posSize(user), size, "position unchanged");
        assertEq(_escrowOwed(relayerEoa), 2 * rounds * MetaTxLib.MAX_RELAYER_FEE, "fees accrued to the relayer");
        assertEq(walletBefore - usdc.balanceOf(user), 2 * rounds * _usdcFee(), "...from the signer's wallet");
        _assertBooks("after the round trips");
    }

    // ─────────────────────────── no collateral fallback ───────────────────────────

    /// @notice A signer with ample collateral but no USDC allowance cannot have the fee taken
    ///         from the bucket instead: the pull reverts and the order stays live.
    function test_relayedCancel_revertsWithoutWalletAllowance() public {
        (address user, uint256 pk, address relayerEoa) = _actor("noAllowance");
        _deposit(user, 10_000 * BAZAAR_SCALE);
        uint256 orderId = _placeLimit(user, true, BAZAAR_SCALE / 10, 45_000 * BAZAAR_SCALE);
        assertEq(usdc.allowance(user, address(pair)), 0, "deposit consumed its exact allowance");

        uint256[] memory ids = _one(orderId);
        CancelReq memory r = _buildRelayedCancel(user, pk, ids);

        vm.prank(relayerEoa);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pair), 0, _usdcFee())
        );
        pair.cancelOrders(ids, r.nonce, r.deadline, r.fee, r.sig, "");

        assertEq(_posCollateral(user), 10_000 * BAZAAR_SCALE, "collateral untouched");
        assertEq(_canceledBlock(orderId), 0, "order untouched");
        assertEq(_escrowOwed(relayerEoa), 0, "no fee accrued");
    }

    /// @notice The wallet path is open to a signer with no ETH and no standing allowance: an
    ///         ERC-2612 permit for the fee rides along outside the signed payload.
    function test_relayedCancel_withPermit() public {
        (address user, uint256 pk, address relayerEoa) = _actor("permit");
        _deposit(user, 10_000 * BAZAAR_SCALE);
        uint256 orderId = _placeLimit(user, true, BAZAAR_SCALE / 10, 45_000 * BAZAAR_SCALE);
        assertEq(usdc.allowance(user, address(pair)), 0, "no standing allowance");

        uint256[] memory ids = _one(orderId);
        CancelReq memory r = _buildRelayedCancel(user, pk, ids);
        bytes memory permitData = _signPermit(user, pk, _usdcFee(), vm.getBlockTimestamp() + 30);

        vm.prank(relayerEoa);
        pair.cancelOrders(ids, r.nonce, r.deadline, r.fee, r.sig, permitData);

        assertGt(_canceledBlock(orderId), 0, "order canceled");
        assertEq(_escrowOwed(relayerEoa), MetaTxLib.MAX_RELAYER_FEE, "relayer's fee funded via the permit");
        assertEq(usdc.allowance(user, address(pair)), 0, "permit covered exactly the fee");
        assertEq(_posCollateral(user), 10_000 * BAZAAR_SCALE, "collateral untouched");
    }

    // ──────────── lifecycle: nothing in the vault moves, so nothing needs freezing ────────────

    /// @notice The settlement window freezes every collateral movement so the total owed that
    ///         finalize derives from the ledgers stays stable. A wallet-funded fee moves neither
    ///         collateral nor the ledger, so a relayed cancel goes through exactly like a
    ///         self-submitted one.
    function test_relayedCancel_allowedDuringSweepWindow() public {
        (address user, uint256 pk, address relayerEoa) = _actor("sweep");
        _deposit(user, 10_000 * BAZAAR_SCALE);
        _allowFees(user);
        uint256 orderId = _placeLimit(user, true, BAZAAR_SCALE / 10, 45_000 * BAZAAR_SCALE);

        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        assertGt(pair.settlementPriceFixedTs(), 0, "sweep window open");

        uint256 collBefore = _posCollateral(user);
        uint256 dBefore = _totalDeposited();
        uint256[] memory ids = _one(orderId);
        CancelReq memory r = _buildRelayedCancel(user, pk, ids);

        vm.prank(relayerEoa);
        pair.cancelOrders(ids, r.nonce, r.deadline, r.fee, r.sig, "");

        assertGt(_canceledBlock(orderId), 0, "relayed cancel works through the sweep window");
        assertEq(_posCollateral(user), collBefore, "collateral frozen");
        assertEq(_totalDeposited(), dBefore, "D frozen");
        assertEq(_escrowOwed(relayerEoa), MetaTxLib.MAX_RELAYER_FEE, "fee pulled from the wallet");
    }

    /// @notice A self-submitted cancel carries no signature, hence no fee, and is unaffected.
    function test_selfSubmittedCancel_allowedDuringSweepWindow() public {
        (address user,,) = _actor("sweepSelf");
        _deposit(user, 10_000 * BAZAAR_SCALE);
        uint256 orderId = _placeLimit(user, true, BAZAAR_SCALE / 10, 45_000 * BAZAAR_SCALE);

        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);

        uint256 collBefore = _posCollateral(user);

        vm.prank(user);
        pair.cancelOrders(_one(orderId), 0, 0, 0, "", "");

        assertGt(_canceledBlock(orderId), 0, "self-submitted cancel still works");
        assertEq(_posCollateral(user), collBefore, "and moves no collateral");
    }

    /// @notice adlScore is pnl / effectiveCollateral, so shaving collateral mid-auction would
    ///         re-rank a listed winner and revert a whole executeAdl batch. The wallet-funded fee
    ///         leaves collateral alone, so a relayed cancel is as safe here as a direct one.
    function test_relayedCancel_allowedDuringAdl() public {
        (address user, uint256 pk, address relayerEoa) = _actor("adl");
        _deposit(user, 20_000 * BAZAAR_SCALE);
        _allowFees(user);
        // Placed BEFORE the trigger (order creation is frozen once ADL is pending), on the ask
        // side so the liquidation's inline unload of the inherited long cannot fill it.
        uint256 orderId = _placeLimit(user, false, BAZAAR_SCALE / 10, 55_000 * BAZAAR_SCALE);

        _triggerRealAdl();

        uint256 collBefore = _posCollateral(user);
        uint256[] memory ids = _one(orderId);
        CancelReq memory r = _buildRelayedCancel(user, pk, ids);

        vm.prank(relayerEoa);
        pair.cancelOrders(ids, r.nonce, r.deadline, r.fee, r.sig, "");

        assertGt(_canceledBlock(orderId), 0, "relayed cancel works during ADL");
        assertEq(_posCollateral(user), collBefore, "adlScore input untouched");
        assertEq(_escrowOwed(relayerEoa), MetaTxLib.MAX_RELAYER_FEE, "fee pulled from the wallet");
    }

    /// @notice De-risking during ADL must stay possible under the user's own gas.
    function test_selfSubmittedCancel_allowedDuringAdl() public {
        (address user,,) = _actor("adlSelf");
        _deposit(user, 20_000 * BAZAAR_SCALE);
        // Ask side: survives the liquidation's inline unload of the inherited long.
        uint256 orderId = _placeLimit(user, false, BAZAAR_SCALE / 10, 55_000 * BAZAAR_SCALE);

        _triggerRealAdl();

        uint256 collBefore = _posCollateral(user);

        vm.prank(user);
        pair.cancelOrders(_one(orderId), 0, 0, 0, "", "");

        assertGt(_canceledBlock(orderId), 0, "self-submitted cancel still works during ADL");
        assertEq(_posCollateral(user), collBefore, "and moves no collateral");
    }
}
