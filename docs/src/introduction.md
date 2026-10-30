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

Every role a traditional exchange reserves for itself is, here, an open job — anyone can take it, whether an individual trader or a professional independent operator. Anyone can list a market. Anyone can fire stop orders, liquidate insolvent positions, unload the vault's inventory, and keep prices fresh — every keeper job pays a bounty (a stop order's is set by its owner). Anyone can capitalize the insurance backstop and earn its fees. Anyone can vote a dying market into settlement. There is no company behind the counter — the marketplace is owned and operated by its own participants.

The protocol itself is immutable and unowned, not as ideology but as product: a marketplace for *everything* can only stay neutral if no one — no team, no company, no committee — is in a position to say no.

## How is bazaar achieving this vision

Four design commitments drive everything else:

**1. The book is fully on-chain — sorted, matched, and settled by the contract itself.**
Orders rest in contract storage and [match on arrival](protocol/matching.md), inside the taker's own transaction. Price-time priority is a property of the sorted book rather than a promise, and there is no off-chain matcher to censor, front-run, or go down.

**2. Almost anything with a feed can be a market — and no committee decides when one closes.**
Perps on equities and real-world assets face questions crypto-only protocols never do: what happens off trading hours, or when the company is acquired and the feed goes dark? Bazaar has a [trading regime for closed markets](protocol/oracle.md) and four independent [termination paths](protocol/termination.md) that end any market in cash settlement. There is no listings committee: a market whose asset is delisted, restructured, or losing its feed is wound down by anyone through a bonded UMA claim, or by a vote of its own insurance LPs — the people whose capital backs it.

**3. Every job an exchange does is an independent, rewarded role.**
Listing markets, insuring them, liquidating positions, firing stop orders, refreshing prices, running frontends, and relaying gasless transactions are open roles. Each pays whoever does the work — a bounty, a fee stream, or a share of the insurance fund's income — so the exchange keeps running as long as the work is worth doing. No single operator is load-bearing: if one keeper goes offline, the bounty stays on the table for the next. See [Earning on Bazaar](guide/earning.md) and [Integrators](guide/integrators.md).

**4. Risk parameters set themselves.**
There are no governance-set leverage tiers or fee schedules. Each market derives its [margin](protocol/margin.md), [insurance target](protocol/insurance.md), and [fees](protocol/fees.md) from its own observed risk: realized volatility, how its liquidations have actually filled, and the gaps it has shown across closures. A market that turns risky tightens its own leverage and bids up its own backstop, with no committee deciding when.
## Reading map

- Want to trade, LP, run keepers, or integrate: [Using Bazaar](guide/using-bazaar.md) + [Deployments](reference/networks.md)
- Trading mechanics: [Orders](protocol/orders.md) → [Arrival Matching](protocol/matching.md) → [Fees](protocol/fees.md)
- Risk machinery: [Margin & Leverage](protocol/margin.md) → [Liquidations](protocol/liquidations.md) → [Auto-Deleveraging](protocol/adl.md) → [Insurance Fund](protocol/insurance.md)
- Operator roles: [Earning on Bazaar](guide/earning.md), [Markets & Listing](protocol/listing.md), [Termination](protocol/termination.md)
- Integration: [Gasless Transactions](protocol/meta-transactions.md), [Contracts](reference/contracts.md), [Protocol Parameters](reference/parameters.md)
