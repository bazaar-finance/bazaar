<p align="center">
  <img src="images/market-in-jaffa.jpg" alt="Bazaar" width="700"/>
  <span class="img-credit">Gustav Bauernfeind, <em>A Market in Jaffa</em>, 1887</span>
</p>

# Introduction

**Bazaar is a fully permissionless perpetual-futures protocol for Arbitrum.** Any asset with a [Pyth](https://pyth.network) price feed — crypto, equities, FX, indices — can be listed through an [UMA Optimistic Oracle](https://uma.xyz) assertion and traded on a fully on-chain central limit order book, margined in USDC.

The protocol is immutable: no owner, no pauser, no upgradeable proxies, no governance token. Every privileged action is either fully permissionless, economically bonded, or adjudicated by UMA's optimistic oracle.

> ⚠️ **Status: pre-audit, work in progress — not yet deployed.** There is no official deployment on any network; do not use with real funds.

## Vision

The aim is in the name: a bazaar — an open marketplace where futures contracts on **any asset with a price can be traded by anyone, against anyone.**

Every role a traditional exchange reserves for itself is, here, an open job — anyone can take it, whether an individual trader or a professional independent operator. Anyone can list a market. Anyone can fire stop orders, liquidate insolvent positions, unload the vault's inventory, and keep prices fresh — every keeper job pays a bounty. Anyone can capitalize the insurance backstop and earn its fees. Anyone can vote a dying market into settlement. There is no company behind the counter — the marketplace is owned and operated by its own participants.

The protocol itself is immutable and unowned, not as ideology but as product: a marketplace for *everything* can only stay neutral if no one — no team, no company, no committee — is in a position to say no.

## How is bazaar achieving this vision

Four design commitments drive everything else:

**1. The book is fully on-chain — sorted, matched, and settled by the contract itself.**
Orders rest in contract storage as two price-sorted linked lists, and [matching happens on arrival](protocol/matching.md): `createOrder` walks the opposing side, fills at each resting maker's limit price, and rests or cancels the remainder — all inside the taker's own transaction. Price-time priority is a structural invariant of the sorted book, not a policy anyone promises to follow, and there is no trusted matcher to censor, front-run, or go down. The few flows with no arriving order to piggyback on — firing stop orders, unloading liquidated inventory — are permissionless keeper jobs that pay bounties.

**2. Almost anything with a feed can be a market — including assets that stop existing.**
Perps on equities and real-world assets need answers that crypto-only protocols never face: What happens off trading hours? What happens when the company is acquired, the feed is decommissioned, or the asset redenominates? Bazaar has a [stale-oracle trading regime](protocol/oracle.md) for market closures and four independent [termination paths](protocol/termination.md) that guarantee every market can always be wound down to cash settlement — without anyone's permission.

**3. Every failure mode ends in a defined state.**
Losses cascade through a fixed waterfall: the trader's own collateral → the per-pair insurance fund → auto-deleveraging → pro-rata haircuts on profits → termination. A liquidated position is inherited by the vault and backed by the pair's insurance fund, which keeps a fifth of its target in reserve. If the expected loss on that inventory exceeds the fund's capital above that reserve, auto-deleveraging closes the most profitable, most leveraged counterparties at the price where the vault breaks even — never at a loss to the deleveraged trader — until what remains could be sold inside the liquidation band. If 24 hours of that cannot get there, the pair terminates automatically and profits are haircut pro-rata, principal senior. There is no path that strands funds behind a revert, and no path that pays out first-come-first-served.

**4. Risk parameters set themselves.**
There are no governance-set leverage tiers or fee schedules. Each market prices its own risk into a single number — the **stress move**, the price move maintenance margin is set to survive — built from realized volatility (a 3% base scaled up to 6×), from how far recent liquidations actually filled past bankruptcy, and, on session-bound markets, from the jumps they have demonstrated across closures. [Margin](protocol/margin.md) is twice that number and the [insurance target](protocol/insurance.md) is equal to it, clamped to 2–10% of open interest, so leverage and the backstop move together instead of on separate curves. The [fees](protocol/fees.md) that fill the fund are the control loop: the taker insurance fee rises steeply below target and rests on its base rate above it, and a depleted fund tightens leverage on top. A market that turns risky tightens its own leverage and bids up its own backstop, with no committee deciding when.

## Reading map

- Want to trade, LP, run keepers, or integrate: [Using Bazaar](guide/using-bazaar.md) + [Deployments](reference/networks.md)
- Trading mechanics: [Orders](protocol/orders.md) → [Arrival Matching](protocol/matching.md) → [Fees](protocol/fees.md)
- Risk machinery: [Margin & Leverage](protocol/margin.md) → [Liquidations](protocol/liquidations.md) → [Auto-Deleveraging](protocol/adl.md) → [Insurance Fund](protocol/insurance.md)
- Operator roles: [Earning on Bazaar](guide/earning.md), [Markets & Listing](protocol/listing.md), [Termination](protocol/termination.md)
- Integration: [Gasless Transactions](protocol/meta-transactions.md), [Contracts](reference/contracts.md), [Protocol Parameters](reference/parameters.md)
