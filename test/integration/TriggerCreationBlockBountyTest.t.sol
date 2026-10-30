// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {OrderView} from "../OrderView.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title TriggerCreationBlockBountyTest
/// @notice A trigger order the stale fallback left unarmed at creation pays its bounty to the
///         owner when it is fired in that same block, whoever fired it. On a session pair the
///         submitter decides whether a creation carries a price: `priceUpdate` sits outside the
///         signed payload, and without one, once the Pyth cache is past MAX_PRICE_STALENESS, the
///         order runs on the stale fallback and a trigger the live price already meets does not
///         arm on arrival. A relayer that rests a signed stop that way and fires it itself in
///         the same block would otherwise collect a bounty the owner keeps when the creation
///         carries the price. The rule is that block only, and only for a stale-fallback
///         creation: a keeper one block later is paid as any other, and so is one firing in the
///         creation block an order whose creation read a fresh price.
contract TriggerCreationBlockBountyTest is IntegrationBase {
    uint256 constant AAPL = 1e18;
    uint256 constant B = 1e18; // a $1 bounty
    uint256 constant FEE = 0.1e18; // the signed relayer fee
    uint256 constant POSITION = 100 * AAPL; // $10,000 at $100

    address internal relayer = makeAddr("relayer");
    address internal k2 = makeAddr("k2"); // an independent keeper
    address internal signer;
    uint256 internal signerPk;

    // ---- aaplPair helpers (IntegrationBase's are hardwired to the continuous BTC pair) ----

    function _depositAapl(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(aaplPair), amount * USDC_SCALE / BAZAAR_SCALE);
        aaplPair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @dev An AAPL update at `priceUsd`, stamped now.
    function _aaplPu(uint256 priceUsd) internal view returns (bytes[] memory) {
        return _priceUpdateFor(AAPL_USD_FEED_ID, priceUsd, uint64(vm.getBlockTimestamp()));
    }

    /// @dev Push `priceUsd` into Pyth's cache and store it as the pair's price, stamped now.
    function _storeAapl(uint256 priceUsd) internal {
        bytes[] memory pu = _aaplPu(priceUsd);
        vm.deal(address(this), 1 ether);
        mockPyth.updatePriceFeeds{value: mockPyth.getUpdateFee(pu)}(pu);
        aaplPair.refreshPrice(new bytes[](0));
    }

    /// @dev Age the Pyth cache past MAX_PRICE_STALENESS, so a call carrying no update runs on
    ///      the stale fallback. The block number is untouched.
    function _ageCache() internal {
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.MAX_PRICE_STALENESS + 1);
    }

    /// @dev Rest or cross a Limit order on the AAPL pair against whatever the Pyth cache holds.
    function _placeAapl(address user, bool isLong, uint256 size, uint256 limitPrice) internal returns (uint256) {
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.Limit;
        s.isLong = isLong;
        s.size = size;
        s.limitPrice = limitPrice;
        s.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
        vm.prank(user);
        aaplPair.createOrder(s, _hintsNone(), new bytes[](0), 0, 0, 0, "", "");
        return _lastCreatedOrderId(aaplPair);
    }

    /// @dev A buy StopLimit whose trigger ($99) a $100 print already meets, carrying `bounty`.
    function _stopLimitSpec(uint256 bounty) internal view returns (BazaarTypes.OrderSpec memory s) {
        s.orderType = BazaarTypes.OrderType.StopLimit;
        s.isLong = true;
        s.size = POSITION;
        s.triggerPrice = _withBounty(99 * BAZAAR_SCALE, bounty);
        s.limitPrice = 101 * BAZAAR_SCALE;
        s.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
    }

    /// @dev A sell StopLoss whose trigger ($101) a $100 print already meets, carrying `bounty`.
    function _stopLossSpec(uint256 bounty) internal pure returns (BazaarTypes.OrderSpec memory s) {
        s.orderType = BazaarTypes.OrderType.StopLoss;
        s.isLong = false;
        s.size = POSITION;
        s.triggerPrice = _withBounty(101 * BAZAAR_SCALE, bounty);
        s.maxSlippageBp = 500;
    }

    function _owedAapl(address who) internal view returns (uint256 owed) {
        (owed,) = lens.claimableFees(address(aaplPair), who);
    }

    function _posSizeAapl(address user) internal view returns (uint256 size) {
        (, size,,,,,) = aaplPair.positionBuckets(user);
    }

    /// @dev A funded signer: collateral on the pair, and a wallet allowance for the fee plus the
    ///      bounty a relayed trigger order pulls.
    function _fundSigner() internal {
        (signer, signerPk) = makeAddrAndKey("signer");
        usdc.mint(signer, INITIAL_USER_BALANCE);
        _depositAapl(signer, 20_000 * BAZAAR_SCALE);
        vm.prank(signer);
        usdc.approve(address(aaplPair), (B + FEE) / 1e12);
    }

    /// @dev The shared setup: a $100 print stored, bob's ask of half the stop's size resting at
    ///      $100.50 for it to fill against, the signer funded, and the cache aged past
    ///      MAX_PRICE_STALENESS so a creation without an update runs on the stale fallback.
    function _agedBookWithAsk() internal {
        _fundSigner();
        _depositAapl(bob, 20_000 * BAZAAR_SCALE);
        _storeAapl(100);
        _placeAapl(bob, false, POSITION / 2, 1005 * BAZAAR_SCALE / 10);
        _ageCache();
    }

    // ---- meta-transactions ----

    function _sign(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(aaplPair.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _createOrderHash(BazaarTypes.OrderSpec memory spec, uint256 deadline, uint256 relayerFee)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                MetaTxLib.CREATE_ORDER_TYPEHASH,
                spec.orderType,
                spec.triggerPrice,
                spec.limitPrice,
                spec.maxSlippageBp,
                spec.size,
                spec.isLong,
                spec.isPostOnly,
                spec.tif,
                spec.expirationBlock,
                spec.integrator,
                uint256(0), // nonce
                deadline,
                relayerFee
            )
        );
    }

    /// @dev The relayer submits `spec` under the signer's signature with no price update: the
    ///      cache is aged, so the creation runs on the stale fallback and the order rests outside
    ///      the book however its trigger stands against the live price.
    function _relayWithoutUpdate(BazaarTypes.OrderSpec memory spec) internal returns (uint256 id) {
        uint256 deadline = vm.getBlockTimestamp() + 5;
        bytes memory sig = _sign(signerPk, _createOrderHash(spec, deadline, FEE));
        vm.prank(relayer);
        aaplPair.createOrder(spec, _hintsNone(), new bytes[](0), 0, deadline, FEE, sig, "");
        id = _lastCreatedOrderId(aaplPair);
        assertEq(OrderView.order(aaplPair, id).filledSize, 0, "setup: the stale fallback left the order unarmed");
        assertFalse(OrderView.order(aaplPair, id).inBook, "setup: it waits outside the book");
        assertEq(_owedAapl(relayer), FEE, "setup: the relayer earned the signed fee");
    }

    // ---- keeper calls ----

    /// @dev Fire `orderId` as `keeper` with a fresh print at `priceUsd`, asserting the bounty
    ///      release it emits. The cache is aged first so the print is the one the call stores;
    ///      the block number is untouched. The update is built before the expectation is set,
    ///      since the mock oracle call would otherwise be the call the expectation binds to.
    function _fireExpectingRelease(
        address keeper,
        uint256 orderId,
        uint256 priceUsd,
        address recipient,
        uint256 amount
    ) internal returns (uint256 executedCount) {
        _ageCache();
        bytes[] memory pu = _aaplPu(priceUsd);
        BazaarTypes.TriggerExec[] memory execs = new BazaarTypes.TriggerExec[](1);
        execs[0].orderId = uint64(orderId);
        vm.expectEmit(true, true, true, true, address(aaplPair));
        emit BazaarTypes.TriggerBountyReleased(aaplPair.pairId(), orderId, recipient, amount);
        vm.prank(keeper);
        executedCount = aaplPair.executeTriggeredOrders(execs, pu);
    }

    // ============================================================
    // The creation block pays the owner
    // ============================================================

    /// @notice The finding's scenario: the relayer withholds the update, so the signed stop rests
    ///         on the stale fallback instead of arming, then fires it itself in the same block
    ///         with a fresh print. The fill is the one an arrival-time arming would have made,
    ///         the bounty goes back to the signer, and the relayer keeps the signed fee only.
    function test_relayerWithholdsUpdate_firesInCreationBlock_bountyReturnsToSigner() public {
        _agedBookWithAsk();
        uint256 id = _relayWithoutUpdate(_stopLimitSpec(B));
        assertEq(
            OrderView.order(aaplPair, id).restedBlock, uint32(vm.getBlockNumber()), "stamped with its creation block"
        );

        assertEq(_fireExpectingRelease(relayer, id, 100, signer, B), 1, "fired");
        assertEq(OrderView.order(aaplPair, id).filledSize, POSITION / 2, "took bob's ask");
        assertTrue(OrderView.order(aaplPair, id).inBook, "the remainder rests");
        assertEq(_owedAapl(signer), B, "the whole bounty back to the signer: resting ends the keeper work");
        assertEq(_owedAapl(relayer), FEE, "the relayer has only the signed fee");
    }

    /// @notice Whoever fires it: an order the owner placed directly on the stale fallback that a
    ///         keeper fires in the same block pays the owner, not the keeper.
    function test_ownerCreatesOnStaleFallback_sameBlockKeeper_ownerKeepsTheBounty() public {
        _agedBookWithAsk();
        BazaarTypes.OrderSpec memory s = _stopLimitSpec(B);
        vm.prank(signer);
        aaplPair.createOrder(s, _hintsNone(), new bytes[](0), 0, 0, 0, "", "");
        uint256 id = _lastCreatedOrderId(aaplPair);
        assertEq(OrderView.order(aaplPair, id).filledSize, 0, "setup: unarmed on the stale fallback");

        assertEq(_fireExpectingRelease(k2, id, 100, signer, B), 1, "fired");
        assertEq(OrderView.order(aaplPair, id).filledSize, POSITION / 2, "filled as the keeper's call made it");
        assertEq(_owedAapl(k2), 0, "nothing for a keeper in the creation block");
        assertEq(_owedAapl(signer), B, "the bounty back to the owner");
    }

    /// @notice The rule is per execution. A creation-block execution that closes a quarter of
    ///         the position returns a quarter of the bounty to the owner; the keeper that finishes
    ///         the close a block later earns the rest.
    function test_creationBlockShareToOwner_laterKeeperEarnsTheRest() public {
        // The signer is long POSITION against bob; carol bids a quarter of it just under the mark.
        _fundSigner();
        _depositAapl(bob, 20_000 * BAZAAR_SCALE);
        _depositAapl(carol, 20_000 * BAZAAR_SCALE);
        _storeAapl(100);
        _placeAapl(bob, false, POSITION, 100 * BAZAAR_SCALE);
        _roll(1);
        _placeAapl(signer, true, POSITION, 100 * BAZAAR_SCALE);
        assertEq(_posSizeAapl(signer), POSITION, "setup: long");
        _placeAapl(carol, true, POSITION / 4, 995 * BAZAAR_SCALE / 10);
        _ageCache();

        uint256 sl = _relayWithoutUpdate(_stopLossSpec(B));
        assertEq(_fireExpectingRelease(relayer, sl, 100, signer, B / 4), 1, "fired in the creation block");
        assertEq(_posSizeAapl(signer), POSITION - POSITION / 4, "a quarter closed against carol");
        assertEq(OrderView.order(aaplPair, sl).canceledBlock, 0, "still live");
        assertEq(_owedAapl(signer), B / 4, "the creation-block share goes to the owner");
        assertEq(_owedAapl(relayer), FEE, "the relayer has only its fee");

        _roll(1);
        _placeAapl(carol, true, POSITION, 995 * BAZAAR_SCALE / 10);
        assertEq(_fireExpectingRelease(k2, sl, 100, k2, B - B / 4), 1, "finished a block later");
        assertEq(_posSizeAapl(signer), 0, "closed");
        assertEq(_owedAapl(k2), B - B / 4, "the rest to the keeper");
        assertEq(_owedAapl(signer), B / 4, "the owner's share is unchanged");
    }

    // ============================================================
    // The rule is the creation block only
    // ============================================================

    /// @notice The same relayer firing one block later is paid as any keeper. The remainder's
    ///         rest re-stamps the order with the arming block, which is why the stamp is read
    ///         before the walk.
    function test_relayerFiresOneBlockLater_isPaidAsAKeeper() public {
        _agedBookWithAsk();
        uint256 id = _relayWithoutUpdate(_stopLimitSpec(B));
        uint32 createdAt = OrderView.order(aaplPair, id).restedBlock;

        _roll(1);
        assertEq(_fireExpectingRelease(relayer, id, 100, relayer, B), 1, "fired");
        assertTrue(OrderView.order(aaplPair, id).inBook, "the remainder rests");
        assertEq(OrderView.order(aaplPair, id).restedBlock, createdAt + 1, "re-stamped by the rest");
        assertEq(_owedAapl(relayer), FEE + B, "the signed fee and the bounty");
        assertEq(_owedAapl(signer), 0, "nothing back to the signer");
    }

    /// @notice An order whose creation read a fresh price carries no stamp, so a keeper that
    ///         fires it in the same block is paid as usual: the trigger was unmet on arrival, and
    ///         a later print in the block meets it.
    function test_freshCreation_sameBlockKeeper_isPaid() public {
        _fundSigner();
        _depositAapl(bob, 20_000 * BAZAAR_SCALE);
        _storeAapl(100);
        _placeAapl(bob, false, POSITION / 2, 1005 * BAZAAR_SCALE / 10);
        // A $102 trigger against a fresh $100: unmet, so the stop waits with no stamp.
        BazaarTypes.OrderSpec memory s = _stopLimitSpec(B);
        s.triggerPrice = _withBounty(102 * BAZAAR_SCALE, B);
        s.limitPrice = 103 * BAZAAR_SCALE;
        vm.prank(signer);
        aaplPair.createOrder(s, _hintsNone(), new bytes[](0), 0, 0, 0, "", "");
        uint256 id = _lastCreatedOrderId(aaplPair);
        assertEq(OrderView.order(aaplPair, id).filledSize, 0, "setup: unmet on arrival");
        assertEq(OrderView.order(aaplPair, id).restedBlock, 0, "a fresh-path creation leaves no stamp");

        assertEq(_fireExpectingRelease(k2, id, 103, k2, B), 1, "fired on a $103 print in the same block");
        assertTrue(OrderView.order(aaplPair, id).inBook, "the remainder rests");
        assertEq(_owedAapl(k2), B, "the keeper is paid");
        assertEq(_owedAapl(signer), 0, "nothing back to the owner");
    }
}
