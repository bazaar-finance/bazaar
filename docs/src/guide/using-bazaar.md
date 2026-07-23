# Using Bazaar

Bazaar is a deployed protocol, not software you need to run. Everything in this guide works against the **official deployment** — canonical addresses live in [Deployments](../reference/networks.md), and only those addresses (plus pairs discoverable from the listed factory) are the real Bazaar.

> The protocol is not yet live on Arbitrum One. Addresses will appear in [Deployments](../reference/networks.md) at launch; until then, everything can be exercised on a testnet or [local stack](quick-start.md).

## Pick your path

| You want to… | Start here | You need |
|---|---|---|
| Trade perps with leverage | [Trading](trading.md) | USDC on Arbitrum |
| Earn yield backstopping a market | [Earning → Insurance LP](earning.md#insurance-lp) | USDC, patience (20-day exit cooldown) |
| Run bots that collect bounties | [Earning → Keeper bounties](earning.md#keeper-bounties) | a bot, gas money |
| Operate matching infrastructure | [Earning → Sequencing](earning.md#sequencing) | ≥ $1,000 bond + off-chain matcher |
| Build a frontend/bot and earn referral fees | [Integrators](integrators.md) | just an address |
| List a new market | [Markets & Listing](../protocol/listing.md) | ≥ $4,000 (bond + insurance seed) |
| Understand the machine | [Protocol chapters](../protocol/architecture.md) | curiosity |

Every role above is **permissionless** — no signups, no whitelists, no API keys. If you can send a transaction, you can participate.

## The five-minute mental model

- Each market ("pair") is its own contract with its own order book, insurance fund, and USDC collateral pool. One net position per wallet per market.
- Orders rest on-chain; bonded **sequencers** batch-match them a few times per second and are slashed if they censor anyone.
- Margin is dynamic: calmer markets allow up to 25× leverage, wilder ones less. Fall below maintenance margin and anyone may liquidate you.
- Losses that liquidations can't cover cascade through a defined waterfall (vault → auto-deleveraging → insurance fund → haircuts) — never first-come-first-served, never socialized by surprise rules.
- Markets on stocks and FX keep working when their venues close, under tightened rules; and any market can be wound down to cash settlement when its underlying dies.
