# Local Development

This page sets up a **local development stack** — building, testing, and running the protocol on Anvil with mocked Pyth/UMA/USDC. If you just want to use the live protocol, start at [Using Bazaar](using-bazaar.md) instead.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- Node.js + npm (for the Pyth Solidity SDK)
- `make`, `jq`

## Install & test

```bash
git clone --recursive <repo-url> && cd bazaar
npm install          # @pythnetwork/pyth-sdk-solidity
forge build
forge test
```

The suite is 844 tests across 74 suites — unit suites per library/mechanism plus end-to-end integration suites, including a zero-sum accounting invariant (`test/integration/ZeroSumInvariantTest.t.sol`). Note that `forge build` is the slow step, not the tests: `via_ir` plus the 150-runs compilation restriction compiles the `BazaarPair` closure twice, so a change to `MatchingEngineLib` costs minutes while the whole suite runs in about nine seconds.

## Local stack on Anvil

Create a `.env` in the repo root (it is gitignored):

```bash
ANVIL_RPC_URL=http://127.0.0.1:8545
ANVIL_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80  # anvil default #0
ANVIL_WALLET=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

Then:

```bash
make anvil           # terminal 1 — local node with tracing
make deploy-anvil    # terminal 2 — full stack + MockPyth/MockUSDC/MockOOv3, mints 10,000 USDC
```

Deployed addresses land in `.anvil-addresses`. From there:

```bash
# List a market (proposes via mock UMA, warps past liveness, settles)
make deploy-pair-anvil FEED_ID=0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace DESC="ETH/USD"

# Push a mock Pyth price
make set-price-anvil FEED_ID=0xff61... PRICE=2000

# Rest a limit order
make create-order-anvil PAIR=0x... LIMIT_PRICE=2000 SIZE=0.01 IS_LONG=true

# Move time (funding, cooldowns, UMA liveness)
make warp-anvil SECONDS=43200
```

`make help` lists everything.

## Building this book

The documentation is an [mdBook](https://rust-lang.github.io/mdBook/):

```bash
mdbook serve docs    # live-reload at http://localhost:3000
mdbook build docs    # static site in docs/book/
```
