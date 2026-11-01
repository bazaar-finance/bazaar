# Batching Orders

Bazaar has no batch form of `createOrder`: each order is one call, because each order is one
signed intent and the [relayer](../protocol/meta-transactions.md) path signs them one at a time.
Cancelling and amending are batched already — `cancelOrders` takes up to 200 ids and
`amendOrders` reprices or resizes up to 32 resting limits in one call — so the only thing that
needs more than one transaction today is placing several new orders at once.

If you need that — a bot quoting both sides, a strategy laddering a side, a one-shot
deposit-and-trade — do it from a **contract account**. A contract that calls the pair several
times in one transaction gets most of what a batch entry point would give, with no change to the
protocol.

## The pattern

A contract becomes the trader. It holds the USDC, it calls `depositCollateral`, `createOrder`,
`amendOrders`, `cancelOrders`, `withdrawCollateral` and `claimFees`, and every one of those sees
`msg.sender` = the contract. Collateral, positions, resting orders and claimable fees belong to the
contract's address; whoever controls the contract controls them.

Any smart wallet that can batch calls works — an ERC-4337 account, a Safe, a session-key wallet.
If you have none, `examples/BazaarTradingAccount.sol` in the repository is the smallest thing that
does the job: an owner, a `receive` for ETH refunds, and one function:

```solidity
struct Call { address target; uint256 value; bytes data; }
function execute(Call[] calldata calls) external payable returns (bytes[] memory results);
```

`execute` runs the calls in order as the account. The first one that fails reverts the whole batch
with that call's own revert data, so a batch is atomic and a failure reads like a direct call's
(`MatchingEngineLib__FillOrKillUnfilled`, say). The example is yours to deploy, one per trader; it
is not part of the protocol and has not been audited with it. The owner key controls everything
the account holds, so treat it accordingly.

### One transaction: fund, deposit, quote

```solidity
BazaarTradingAccount.Call[] memory calls = new BazaarTradingAccount.Call[](5);

// The account already holds the USDC (transfer it there, or have the batch pull it with
// transferFrom against an allowance you gave the account).
calls[0] = Call(usdc, 0, abi.encodeCall(IERC20.approve, (pair, 20_000e6)));
calls[1] = Call(pair, 0, abi.encodeCall(pair.depositCollateral, (20_000e18, 0, 0, 0, "", "")));

// The first order carries the Pyth update and the ETH to pay for it.
calls[2] = Call(pair, pythFee, abi.encodeCall(pair.createOrder, (bid49k, hints49k, priceUpdate, 0, 0, 0, "", "")));
// The rest read the price that call stored, so they send no update and no ETH.
calls[3] = Call(pair, 0, abi.encodeCall(pair.createOrder, (bid48k, hints48k, noUpdate, 0, 0, 0, "", "")));
calls[4] = Call(pair, 0, abi.encodeCall(pair.createOrder, (ask52k, hints52k, noUpdate, 0, 0, 0, "", "")));

account.execute{value: pythFee}(calls);
```

Notes on the pieces:

- **Price update once.** A pair reads Pyth's on-chain price first and only parses `priceUpdate`
  when that price is older than 3 seconds or outside the confidence cap. The first call in the batch stores a fresh price; later
  calls in the same transaction find it and skip the update, so give them an empty array. The
  ETH for the update rides on that first call's `value`; whatever the pair does not spend is
  refunded to the account, and a later batch can forward it (`Call(owner, amount, "")`).
- **Hints per order.** `MatchHints` are not signed, so compute them off-chain against the live
  book right before submitting (`BazaarPairLens.findPredecessor`), one set per order. A wrong
  hint can only fail the placement, never misplace an order.
- **`integrator`** goes on each spec as usual.
- **Meta-transaction fields** (`nonce`, `deadline`, `relayerFee`, `signature`, `permitData`) are
  zero and empty: the account submits for itself, so nothing is relayed.
- **Getting money out.** `withdrawCollateral` pays the account, not the owner; put a USDC
  `transfer` to the owner in the same batch, as the test does. Anything else the pair owes the
  account (a cancelled trigger order's bounty, say) is credited to the account's address, and
  `claimFees` pays it only to its caller, so claim through the account.

## What still holds per order

The pair sees a sequence of ordinary calls, so every rule applies to each one:

- **The account is one trader.** Its 32 active Limit+StopLimit orders, its one TakeProfit and one
  StopLoss, its single net position per market — all shared by everything the account does.
- **Your own orders never fill each other.** A bid and an ask from the account that cross are a
  self-match: the later one is cancelled, the earlier one keeps resting. Quote both sides at
  prices that do not cross.
- **An auto-cancel is not a failure.** An order the margin gate or the self-match rule cancels
  returns normally, with an `OrderUpdated` carrying `Canceled` and a reason; the batch goes on.
  A fill-or-kill that cannot fill, a bad hint, or a margin check at creation reverts the call,
  and with it the batch.
- **Gas per order is unchanged, and so is the cap.** A crossing order can walk up to 32 resting
  makers at roughly 90k gas each, about 3.4M for a full walk, so a batch of about nine full walks
  reaches Arbitrum's 32M per-transaction limit. Keep batches of takers short; resting orders are
  cheap.

## What batching saves

Three things, none of them specific to the sample contract:

- **One transaction's overhead** instead of one per order: the 21,000 gas every transaction pays
  before it runs, and the L1 data charge on its signature and envelope bytes.
- **Warm storage.** The second and later calls in a transaction read what the first one touched
  at 100 gas instead of 2,100. In the repository's measurement (`TradingAccountTest`, mock oracle
  and mock USDC) four resting orders cost about 1.95M gas as four separate transactions and about
  1.32M as one batch through the example account, with the batch also carrying the USDC approval
  and the deposit. The same four orders as four direct calls inside one transaction cost about
  1.38M, so nearly all of the saving is the warm storage, not the contract.
- **One price store per transaction**, which the cache-first rule gives every caller in the same
  block anyway.

What it does not save: the work each `createOrder` does on its own — the margin gate, the order
and position writes, the walk, the health check. A batch entry point in the pair would trim some
of that; the gain is tens of thousands of gas per order against the figures above, which is why
the protocol does not carry one. The orders an account already holds do not add to that work:
the margin gate bounds their reservation from a per-account tally and reads them one by one only
when the bound does not clear the account (see [initial margin](../protocol/margin.md#the-resting-order-tally)).

## Relayed users

A relayed trader signs one `createOrder` at a time; there is no signed batch form. A frontend
that relays can still land several of a user's orders in one transaction by submitting the
signed calls from its own contract in sequence — each with its own signature, nonce and fee —
and the warm-storage saving applies to that transaction too. The signatures are independent,
though: a relayer may submit some and not others.
