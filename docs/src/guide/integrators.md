# Integrators: Earn Referral Fees

If you put an order-creation UI in front of users — a web frontend, a Telegram bot, a trading terminal, an aggregator, a vault strategy — Bazaar pays you **protocol-level referral fees** on every fill your users generate. No registration, no agreement, no API key, no permission: the fee is a field on the order.

## How to become one

Put your address in the `integrator` field of the `OrderSpec` of every `createOrder` your product submits:

```solidity
pair.createOrder(
    BazaarTypes.OrderSpec({
        orderType: orderType, isLong: isLong, isPostOnly: isPostOnly, tif: tif,
        size: size, triggerPrice: triggerPrice, limitPrice: limitPrice,
        maxSlippageBp: maxSlippageBp, expirationBlock: expirationBlock,
        integrator: integrator   // ← your address. That's the entire integration.
    }),
    hints,               // book-position hints, computed off-chain from the live book
    priceUpdate, nonce, deadline, relayerFee, signature, permitData
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

Payment accrues **per matching transaction**: the matching engine accumulates your fees across the transaction's fills and credits them to your address's claimable balance on that pair, emitting `FeeAccrued` as it settles. Withdraw with `claimFees()` on each pair whenever the balance is worth the gas — no minimum, and the balance is reserved against the pair's cash in every solvency check, so it can be neither spent nor haircut while it waits.

## Stack it with relayer fees

Integrators are naturally positioned to run the [meta-transaction relayer](../protocol/meta-transactions.md) for their users: your users sign EIP-712 payloads (no ETH needed, USDC approval via permit), your relayer submits them and earns up to **$1 per action** in USDC on top of the referral fee — accrued to the same claimable balance, so one claim sweeps both revenue streams. Gasless UX for them, second revenue stream for you. `BazaarPairLens.getEip712Constants()` and `getTypehashes()` expose everything needed to build the signatures.

## Fine print

- The 1% protocol-wide [bug-bounty tax](../protocol/fees.md) applies to integrator fees like every other stream — you receive 99% of the 0.25 bp.
- Nothing is pushed to your address, so a fill can never fail because of it. If the address can't receive USDC (e.g. blacklisted), the balance simply sits unclaimable until it can — use a boring, clean address.
- The `integrator` field is per-order and immutable once set — users of your UI can't be siphoned retroactively, and you can't claim orders you didn't originate.
- Setting `integrator = address(0)` charges no integrator fee at all — direct-to-contract traders skip the 0.25 bp entirely. Your referral fee is a real surcharge on your users' fills, so the convenience your product adds has to be worth a quarter of a basis point.

## Checklist for a production integration

1. Set `integrator` on every order (and test that fills emit `FeeAccrued` for your address). `OrderFilled` is the only per-fill event — it carries `fillSize`, `executionPrice`, the total `fee` charged that side, and an `isMaker` flag, and a pair match emits one per side — so index that to attribute your revenue.
2. Decide gasless vs. direct: every path needs a Pyth update at most 2 seconds old. Relaying is the dependable way to meet that, since `priceUpdate` is outside the signed payload and your relayer attaches a fresh price at submission. A direct-signing UI has to either land inside the window or send an empty `priceUpdate` and accept that the call reverts whenever the pair's cached price has aged out.
3. Read [Orders](../protocol/orders.md) for the per-user caps your UI must respect (32 active Limit+StopLimit orders, 1 TP + 1 SL per position) and surface auto-cancel events (`OrderUpdated` with `Canceled`) to users.
4. Use `BazaarPairLens` for all read paths — solvency, margin, share prices — rather than re-deriving them client-side. Insurance shares are priced at the mark, so quote LP flows with `quoteInsuranceDeposit` / `quoteInsuranceWithdrawal` at the live Pyth price your relayer will attach; `getInsuranceSharePrice` reports the redemption value at the pair's stored mark.
