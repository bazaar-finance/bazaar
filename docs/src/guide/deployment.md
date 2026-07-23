# Self-Deployment

> **You do not need this page to use Bazaar.** The canonical deployment's addresses are in [Deployments](../reference/networks.md), and [Using Bazaar](using-bazaar.md) covers trading, LPing, sequencing, and integrating against it. This page is for protocol developers and for anyone standing up an independent deployment — in which case note the [AGPL-3.0 network clause](../license.md): a fork operated as a service must publish its modified source.

Deployment is **two-step** because the heavy logic lives in externally deployed libraries that are linked by address (see [Architecture](../protocol/architecture.md#code-size-strategy)).

## Step 1 — deploy the external libraries

```bash
forge script script/DeployLibraries.s.sol --rpc-url <network> --broadcast
```

This deploys the 8 DELEGATECALL libraries (`InsuranceVaultLib`, `LiquidationLib`, `OrderManagementLib`, `AdlLib`, `MatchingEngineLib`, `CollateralLib`, `RiskParamsLib`, `FundingLib`) and prints a ready-to-paste block:

```toml
libraries = [
    "src/libraries/InsuranceVaultLib.sol:InsuranceVaultLib:0x...",
    ...
]
```

Paste it into `foundry.toml` under `[profile.default]` (the commented template is already there).

## Step 2 — deploy the core

```bash
make deploy-arb-sepolia    # or: deploy-arb-mainnet (asks for confirmation)
```

`script/DeployBazaar.s.sol` deploys, in order: `BazaarOracle` → `BazaarPairLens` → the `BazaarPair` implementation → `BazaarSequencer` and `BazaarPairTerminator` (constructed against the factory address *predicted* via `vm.computeCreateAddress`) → `BazaarFactory`, then asserts the prediction held. The factory constructor independently re-checks the wiring (`Factory__WiringMismatch`), so a bad prediction cannot deploy a half-wired system.

The sequencer and terminator are pre-deployed against the predicted address because inlining their deployment in the factory constructor would push its initcode past the EIP-3860 limit.

## Environment

| Variable | Used by |
|---|---|
| `ARBITRUM_MAINNET_RPC_URL`, `ARBITRUM_SEPOLIA_RPC_URL`, `BASE_SEPOLIA_RPC_URL` | `foundry.toml` RPC endpoints |
| `ACCOUNT`, `SENDER` | keystore account for `forge script` |
| `ARBISCAN_API_KEY`, `BASESCAN_API_KEY` | contract verification |
| `ANVIL_RPC_URL`, `ANVIL_PRIVATE_KEY`, `ANVIL_WALLET` | local Makefile targets |

## Network support

See [Networks](../reference/networks.md) for chain IDs and external-contract addresses. Note that `BazaarPair` reads Arbitrum's `ArbSys` precompile (`0x64`) for L2 block numbers — the protocol runs only on Arbitrum chains. The Base Sepolia configuration exists solely to exercise the real UMA OOv3 dispute flow, which has no official Arbitrum Sepolia deployment.
