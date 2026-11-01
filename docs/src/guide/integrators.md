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

**0.25 bp (0.0025%) of the fill's notional from each side of the fill that carries your address.** The integrator fee is charged on both sides of a fill, not split between them: the maker pays 0.25 bp of the notional to the integrator on its order, and the taker pays 0.25 bp to the integrator on its own. When both orders carry your address — one of your users resting, another taking — you collect both sides, **0.5 bp of the fill's notional**. A counterparty that came through another frontend pays its 0.25 bp to that integrator; one that came direct to the contract (`integrator = address(0)`) pays none, and neither does the vault when it unloads liquidated inventory into your user's resting order. You are paid on every partial fill, for the entire life of the order (a resting limit that fills 40 times pays you 40 times).

| Monthly traded notional | Your users on one side of each fill | Your users on both sides |
|---|---|---|
| $1M | $25 | $50 |
| $10M | $250 | $500 |
| $100M | $2,500 | $5,000 |
| $1B | $25,000 | $50,000 |

Payment accrues **per matching transaction**: the matching engine accumulates your fees across the transaction's fills and credits them to your address's claimable balance on that pair, emitting `FeeAccrued` as it settles. Withdraw with `claimFees()` on each pair whenever the balance is worth the gas — no minimum, and the balance is reserved against the pair's cash in every solvency check, so it can be neither spent nor haircut while it waits.

## Stack it with relayer fees

Integrators are naturally positioned to run the [meta-transaction relayer](../protocol/meta-transactions.md) for their users: your users sign EIP-712 payloads (no ETH needed, USDC approval via permit), your relayer submits them and earns up to **$1 per action** in USDC on top of the referral fee — accrued to the same claimable balance, so one claim sweeps both revenue streams. Gasless UX for them, second revenue stream for you. `BazaarPairLens.getEip712Constants()` and `getTypehashes()` expose everything needed to build the signatures.

## Fine print

- The 1% protocol-wide [bug-bounty tax](../protocol/fees.md) applies to integrator fees as it does to insurance fees — you receive 99% of each side's 0.25 bp, so the table above is before that 1%.
- Nothing is pushed to your address, so a fill can never fail because of it. If the address can't receive USDC (e.g. blacklisted), the balance simply sits unclaimable until it can — use a boring, clean address.
- The `integrator` field is per-order and immutable once set — users of your UI can't be siphoned retroactively, and you can't claim orders you didn't originate.
- Setting `integrator = address(0)` charges no integrator fee at all — direct-to-contract traders skip the 0.25 bp on their side entirely. Your referral fee is a real surcharge on your users' fills — each of them pays 0.25 bp of every fill their order takes part in — so the convenience your product adds has to be worth a quarter of a basis point.

## Your users, your jurisdiction

Bazaar's contracts cannot tell who is calling them. There is no registration, no identity check, no geographic restriction and no list of blocked addresses — and with no owner, no pauser and no upgradeable proxy, nobody can add one. Any address that can sign a transaction reaches every market on the same terms. The protocol is incapable of deciding whom it serves, so it does not.

That decision belongs to whoever puts an interface in front of users. If you run a frontend, a bot, a terminal, an aggregator or a relayer, you decide:

- **whom you serve** — which users and which regions your product accepts, and how you enforce it;
- **what you offer** — which markets you show and how you present them. A perp on an equity, an index or an FX rate can fall under rules in some jurisdictions that a crypto perp does not;
- **what you submit** — a relayer chooses which signed payloads it puts on-chain.

You are responsible for complying with the laws and regulations that apply where you operate and where your users are — licensing, KYC/AML, sanctions screening, geographic restrictions, derivatives and securities rules, consumer-protection and marketing rules, and tax reporting among them. Bazaar is not responsible for whom an interface serves or how it operates: the protocol has no way to see, screen or turn away any caller, and an integrator or relayer fee is set by a field on the user's own transaction, not earned under any agreement with Bazaar.

Nothing in these docs is legal advice. Get counsel in the jurisdictions you serve before you launch.

## Checklist for a production integration

1. Set `integrator` on every order (and test that fills emit `FeeAccrued` for your address). Every fill emits exactly one `Trade`, naming the maker and taker, their order IDs, `fillSize`, `price` and each side's fee, and `OrderUpdated` reports each order's `integrator` — join the two to attribute your revenue.
2. Decide gasless vs. direct: every order path needs a Pyth price at most 3 seconds old. Relaying is the dependable way to meet that, since `priceUpdate` is outside the signed payload and your relayer attaches a fresh price at submission. A direct-signing UI has to either land inside the window or send an empty `priceUpdate` and accept that the call reverts whenever Pyth's on-chain price for the feed has aged out (a market with trading hours falls back to its last stored price instead, under the [stale-price rules](../protocol/oracle.md#the-stale-price-regime-market-hours)).
3. A bot or vault that places several orders at once should trade from a contract account and batch the calls into one transaction — see [Batching Orders](batching.md) for what that saves and the rules that still apply per order. Read [Orders](../protocol/orders.md) for the per-user caps your UI must respect (32 active Limit+StopLimit orders, 1 TP + 1 SL per position) and surface auto-cancel events (`OrderUpdated` with `Canceled`) to users — its `cancelReason` says why the order died.
4. Use `BazaarPairLens` for all read paths — solvency, margin, share prices — rather than re-deriving them client-side. Insurance shares are priced at the mark, so quote LP flows with `quoteInsuranceDeposit` / `quoteInsuranceWithdrawal` at the live Pyth price your relayer will attach; `getInsuranceSharePrice` reports the redemption value at the pair's stored mark. For withdrawal UX, an exit on a live pair is at least two `executeInsuranceWithdrawal` calls: the first locks and pays nothing, and `getInsuranceWithdrawalLock` then reports when the next can land and the amount it can pay at most. While the vault holds liquidated inventory a paying call is held to the fund's headroom (free capital less the reserve and the cost of finishing the inventory, valued together at whichever edge of the unload band makes their sum larger), so it can pay part of the claim and leave the rest requested, under the lock scaled to it, for another paying call in the window. `getInsuranceWithdrawalBudget` reports what the pair's shared 6-hour withdrawal budget still admits; it is the number execution enforces, but other insurers draw on the same budget and the check runs at the paying call, not at request or lock. Each relayed call pays whoever submits it: a relayed lock's fee is pulled from the LP's wallet, like a relayed request's, so it needs an allowance or a `permitData`, while the paying call's fee comes out of the payout.
5. Build history (trades, candles, order and position timelines, pair status) from events, and live state from the lens. `Trade` feeds the tape and candles directly — a vault unload fill names the pair itself as taker, so no fill is missed. `OrderUpdated` reports every create, trigger and cancel, `OrderAmended` every amendment (new price, size and queue position; the rest of the order is as its creation left it, its fills aside), `NewPriceUpdateAdded` every stored oracle price with the funding index it accrued to, and `InsolvencySettlementFixed` / `AdlResolved` the pair status changes no other contract announces. On the terminator, every UMA termination proposal ends in exactly one resolution event: `TerminationProposalAccepted`, `TerminationScheduleRefused`, `TerminationProposalSuperseded` (resolved TRUE with nothing left to do) or `TerminationProposalRejected` (resolved FALSE). Most of these are emitted from the pair's address by its linked libraries and are missing from the compiler's `BazaarPair` ABI: `make abis` writes one that includes them.
6. Decide which users, regions and markets you serve, and how you enforce that, before you launch — the contracts will not do it for you (see [Your users, your jurisdiction](#your-users-your-jurisdiction)).
