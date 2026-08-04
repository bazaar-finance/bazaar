<p align="center">
  <img src="images/bazaar-logo.png" alt="Bazaar" width="500"/>
</p>

# Introduction

**Bazaar is a fully permissionless perpetual-futures protocol for Arbitrum.** Any asset with a [Pyth](https://pyth.network) price feed — crypto, equities, FX, indices — can be listed through an [UMA Optimistic Oracle](https://uma.xyz) assertion and traded on a fully on-chain central limit order book, margined in USDC.

The protocol is immutable: no owner, no pauser, no upgradeable proxies, no governance token. Every privileged action is either fully permissionless, economically bonded, or adjudicated by UMA's optimistic oracle.

> ⚠️ **Status: pre-audit, work in progress — not yet deployed.** There is no official deployment on any network; do not use with real funds.

## Vision

The aim is in the name: a bazaar — an open marketplace where **anything with a price can be traded by anyone, against anyone.**

Every role a traditional exchange reserves for itself is, here, an open job — anyone can take it, whether an individual trader or a professional independent operator. Anyone can list a market. Anyone can run a sequencer and match orders. Anyone can keep positions honest and collect the bounties for it. Anyone can capitalize the insurance backstop and earn its fees. Anyone can vote a dying market into settlement. There is no company behind the counter — the marketplace is owned and operated by its own participants.

The protocol itself is immutable and unowned, not as ideology but as product: a marketplace for *everything* can only stay neutral if no one — no team, no company, no committee — is in a position to say no.

## Why Bazaar is built the way it is

Three design commitments drive everything else:

**1. The book is on-chain; only the *sorting* is off-chain.**
Orders rest in contract storage. A permissionless, bonded *sequencer* periodically submits the resting order IDs in sorted lists, and the contract re-verifies the sort and matches deterministically in three passes. This keeps the matching semantics trustless while avoiding the gas cost of on-chain insertion into a sorted book. Sequencer honesty is not assumed — it is enforced by [fraud proofs](protocol/sequencers.md): censoring an order or mislabeling a batch as price-stale is provable on-chain and slashes the sequencer's bond.

**2. Anything with a feed can be a market — including assets that stop existing.**
Perps on equities and real-world assets need answers that crypto-only protocols never face: What happens off trading hours? What happens when the company is acquired, the feed is decommissioned, or the asset redenominates? Bazaar has a [stale-oracle trading regime](protocol/oracle.md) for market closures and five independent [termination paths](protocol/termination.md) that guarantee every market can always be wound down to cash settlement — without anyone's permission.

**3. Every failure mode ends in a defined state.**
Losses cascade through a fixed waterfall: liquidation → the vault unwinds inherited inventory on the book → auto-deleveraging Dutch auction → per-pair insurance fund → pro-rata profit haircuts with principal always reserved → termination. There is no path that strands funds behind a revert, and no path that pays out first-come-first-served.

## Reading map

- Want to trade, LP, sequence, or integrate: [Using Bazaar](guide/using-bazaar.md) + [Deployments](reference/networks.md)
- Trading mechanics: [Orders](protocol/orders.md) → [Batch Matching](protocol/matching.md) → [Fees](protocol/fees.md)
- Risk machinery: [Margin & Leverage](protocol/margin.md) → [Liquidations](protocol/liquidations.md) → [Auto-Deleveraging](protocol/adl.md) → [Insurance Fund](protocol/insurance.md)
- Operator roles: [Sequencers & Fraud Proofs](protocol/sequencers.md), [Markets & Listing](protocol/listing.md), [Termination](protocol/termination.md)
- Integration: [Gasless Transactions](protocol/meta-transactions.md), [Contracts](reference/contracts.md), [Protocol Parameters](reference/parameters.md)
