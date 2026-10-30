# Deployments

This page is the **canonical registry of official Bazaar deployments**. If an address is not listed here (or reachable from `BazaarFactory.getAllPairs()` on a factory listed here), it is not part of the official deployment — anyone can deploy an AGPL fork, so always verify addresses against this page.

## Arbitrum One (42161) — production target

**Official Bazaar deployment: not yet live.** Addresses will be published here at launch:

| Contract | Address |
|---|---|
| `BazaarFactory` | *TBD* |
| `BazaarPairTerminator` | *TBD* |
| `BazaarOracle` | *TBD* |
| `BazaarPairLens` | *TBD* |
| `BazaarPair` implementation | *TBD* |

Individual markets are discoverable on-chain from the factory (`getAllPairs()` / `getPairAddress(pairId)`) — the factory is the root of trust for what counts as a real Bazaar pair.

The twelve external libraries these contracts link — eleven by the `BazaarPair` implementation, `ClaimTextLib` by the factory and the terminator — are recorded in `deployments/42161/libraries.args` by deploy step 1 (see [Self-Deployment](../guide/deployment.md)); the record is regenerated whenever the library set changes.

External dependencies on Arbitrum One:

| Contract | Address |
|---|---|
| Pyth | `0xe15357fB7ab31E091583b9c4b4135BB2f176f38e` |
| USDC (native) | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| UMA Optimistic Oracle V3 | `0xa6147867264374F324524E30C02C331cF28aa879` |

## Arbitrum Sepolia (421614) — testnet

**Official Bazaar testnet deployment: not yet live.** Addresses will be published here when it goes up:

| Contract | Address |
|---|---|
| `BazaarFactory` | *TBD* |
| `BazaarPairTerminator` | *TBD* |
| `BazaarOracle` | *TBD* |
| `BazaarPairLens` | *TBD* |
| `BazaarPair` implementation | *TBD* |

The twelve external libraries are recorded in `deployments/421614/libraries.args` by deploy step 1, regenerated whenever the library set changes.

External dependencies on Arbitrum Sepolia:

| Contract | Address |
|---|---|
| Pyth | `0x0B73614636C855Bf23F342F307FB981A3e47f42B` |
| USDC (testnet) | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` |
| UMA OOv3 | **mock** (`OwnedMockOptimisticOracleV3`), deployed by the script and owned by the deploying account, which alone can force-settle assertions, resolve disputes, and set the identifier whitelist and minimum bond (Bazaar's assertions set their own liveness periods). UMA's own Arbitrum Sepolia OOv3 is not used: it does not accept Circle's test USDC as bond collateral, and its stand-in DVM lets anyone resolve a dispute |

## Anvil (31337)

`make deploy-anvil` deploys `MockPyth`, `MockUSDC` (mints 10,000 to your wallet), and `MockOptimisticOracleV3` (Bazaar's assertions set their own liveness periods), and etches `MockArbSys` at the `ArbSys` precompile address (`0x64`). Forge deploys the twelve libraries itself in the same run, so no `libraries.args` record is kept for anvil. The Bazaar protocol addresses, with the `MockUSDC` and `MockOptimisticOracleV3` addresses, are written to `.anvil-addresses`, which the other anvil make targets read.

External-dependency configuration for every network lives in `script/HelperConfig.s.sol`.
