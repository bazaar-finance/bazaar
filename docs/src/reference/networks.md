# Deployments

This page is the **canonical registry of official Bazaar deployments**. If an address is not listed here (or reachable from `BazaarFactory.getAllPairs()` on a factory listed here), it is not part of the official deployment — anyone can deploy an AGPL fork, so always verify addresses against this page.

## Arbitrum One (42161) — production target

**Official Bazaar deployment: not yet live.** Addresses will be published here at launch:

| Contract | Address |
|---|---|
| `BazaarFactory` | *TBD* |
| `BazaarSequencer` | *TBD* |
| `BazaarPairTerminator` | *TBD* |
| `BazaarOracle` | *TBD* |
| `BazaarPairLens` | *TBD* |
| `BazaarPair` implementation | *TBD* |

Individual markets are discoverable on-chain from the factory (`getAllPairs()` / `getPairAddress(pairId)`) — the factory is the root of trust for what counts as a real Bazaar pair.

External dependencies on Arbitrum One:

| Contract | Address |
|---|---|
| Pyth | `0xff1a0f4744e8582DF1aE09D5611b887B6a12925C` |
| USDC (native) | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| UMA Optimistic Oracle V3 | `0xa6147867264374F324524E30C02C331cF28aa879` |

## Arbitrum Sepolia (421614) — testnet

**Official Bazaar testnet deployment: not yet live.** Addresses will be published here when it goes up:

| Contract | Address |
|---|---|
| `BazaarFactory` | *TBD* |
| `BazaarSequencer` | *TBD* |
| `BazaarPairTerminator` | *TBD* |
| `BazaarOracle` | *TBD* |
| `BazaarPairLens` | *TBD* |
| `BazaarPair` implementation | *TBD* |

External dependencies on Arbitrum Sepolia:

| Contract | Address |
|---|---|
| Pyth | `0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF` |
| USDC (testnet) | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` |
| UMA OOv3 | **mock** (deployed with 2 h liveness) — UMA has no official Arbitrum Sepolia deployment |

## Base Sepolia (84532) — UMA dispute testing only

| Contract | Address |
|---|---|
| Pyth | `0xA2aa501b19aff244D90cc15a4Cf739D2725B5729` |
| USDC | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| UMA OOv3 (real) | `0x0F7fC5E6482f096380db6158f978167b57388deE` |

> `BazaarPair` requires Arbitrum's `ArbSys` precompile for L2 block numbers, so the pair cannot run on Base. This configuration exists to exercise the full real-UMA dispute flow end to end.

## Anvil (31337)

`make deploy-anvil` deploys `MockPyth`, `MockUSDC` (mints 10,000 to your wallet), and `MockOptimisticOracleV3` (2 h liveness). Bazaar protocol addresses are written to `.anvil-addresses`.

External-dependency configuration for every network lives in `script/HelperConfig.s.sol`.
