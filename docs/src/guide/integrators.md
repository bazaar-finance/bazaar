# Integrators: Earn Referral Fees

If you put an order-creation UI in front of users — a web frontend, a Telegram bot, a trading terminal, an aggregator, a vault strategy — Bazaar pays you **protocol-level referral fees** on every fill your users generate. No registration, no agreement, no API key, no permission: the fee is a field on the order.

## How to become one

Put your address in the `integrator` parameter of every `createOrder` your product submits:

```solidity
pair.createOrder(
    orderType, triggerPrice, limitPrice, maxSlippageBp, size,
    isLong, isPostOnly, expirationBlock,
    integrator,          // ← your address. That's the entire integration.
    priceUpdate, nonce, deadline, relayerFee, signature
);
```

That's it. You are now an integrator.

## What you earn

**0.25 bp (0.0025%) of the notional of every fill of every order that carries your address** — maker and taker orders alike, on every partial fill, for the entire life of the order (a resting limit that fills 40 times pays you 40 times).

| Monthly volume through your product | Your referral revenue |
|---|---|
| $1M | $25 |
| $10M | $250 |
| $100M | $2,500 |
| $1B | $25,000 |

Payment is **automatic and per-batch**: the matching engine accumulates your fees across each batch and transfers USDC to your address when the batch settles. No claiming, no escrow, no minimum.

## Stack it with relayer fees

Integrators are naturally positioned to run the [meta-transaction relayer](../protocol/meta-transactions.md) for their users: your users sign EIP-712 payloads (no ETH needed, USDC approval via permit), your relayer submits them and collects up to **$1 per action** in USDC on top of the referral fee. Gasless UX for them, second revenue stream for you. `BazaarPairLens.getEip712Constants()` and `getTypehashes()` expose everything needed to build the signatures.

## Fine print

- The 1% protocol-wide [bug-bounty tax](../protocol/fees.md) applies to integrator fees like every other stream — you receive 99% of the 0.25 bp.
- Payouts use a non-reverting transfer; if your address can't receive USDC (e.g. blacklisted), that batch's fee is forfeited to the pair's insurance fund. Use a boring, clean address.
- The `integrator` field is per-order and immutable once set — users of your UI can't be siphoned retroactively, and you can't claim orders you didn't originate.
- Setting `integrator = address(0)` charges no integrator fee at all — direct-to-contract traders skip the 0.25 bp entirely. Your referral fee is a real surcharge on your users' fills, so the convenience your product adds has to be worth a quarter of a basis point.

## Checklist for a production integration

1. Set `integrator` on every order (and test that fills emit your address's transfers). `OrderFilled` is the only per-fill event — it carries `fillSize`, `executionPrice`, the total `fee` charged that side, and an `isMaker` flag, and a pair match emits one per side — so index that to attribute your revenue.
2. Decide gasless vs. direct: relayed calls need the 2-second price-staleness tier — your relayer should attach a fresh Pyth update to each call.
3. Read [Orders](../protocol/orders.md) for the per-user caps your UI must respect (100 resting limits, 1 market order, 1 TP + 1 SL per position) and surface auto-cancel events (`OrderUpdated` with `Canceled`) to users.
4. Use `BazaarPairLens` for all read paths — solvency, margin, share prices — rather than re-deriving them client-side.
