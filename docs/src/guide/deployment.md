# Self-Deployment

> **You do not need this page to use Bazaar.** The canonical deployment's addresses are in [Deployments](../reference/networks.md), and [Using Bazaar](using-bazaar.md) covers trading, LPing, sequencing, and integrating against it. This page is for protocol developers and for anyone standing up an independent deployment — in which case note the [AGPL-3.0 network clause](../license.md): a fork operated as a service must publish its modified source.

Deployment is **two-step** because the heavy logic lives in externally deployed libraries that are linked by address (see [Architecture](../protocol/architecture.md#code-size-strategy)).

## Step 1 — deploy the external libraries

```bash
make deploy-libs-arb-sepolia    # or: deploy-libs-arb-mainnet (asks for confirmation)
```

`BazaarPair` carries a link reference for **ten** DELEGATECALL libraries — `InsuranceVaultLib`, `LiquidationLib`, `OrderManagementLib`, `AdlLib`, `MatchingEngineLib`, `CollateralLib`, `RiskParamsLib`, `FundingLib`, `TerminationLib`, `MetaTxLib` — and every one of them must be deployed and linked before the pair implementation can go out.

The script deploys all ten and records their `--libraries` flags in `deployments/<chainid>/libraries.args`. Nothing is pasted by hand, and nothing is written to `foundry.toml`: `libraries` there is a single global key with no per-network scoping, so one shared list would let a rehearsal network's addresses be linked into a production build — where they hold no code, and every `DELEGATECALL` from the pair would land on an empty account. Keying the record by chain id makes that unrepresentable.

The library list lives in one place, `_libNames()` in the script; the artifact id, the link path and the emitted flag are all derived from it, so a library cannot be deployed but left out of the link flags. Real networks' records are committed as deployment provenance; the local Anvil chain's (`deployments/31337/`) is gitignored as throwaway.

## Step 2 — deploy the core

```bash
make deploy-arb-sepolia    # or: deploy-arb-mainnet (asks for confirmation)
```

The target passes that chain's recorded flags to `forge` and refuses to run if the file for its chain is missing, so step 2 cannot silently produce an unlinked or cross-linked deployment.

The per-chain file only helps if the RPC alias actually serves the chain the target names — the args path is chosen by the make target, not read off the network. Both scripts therefore assert `block.chainid` against the `EXPECTED_CHAIN_ID` the target passes and abort before broadcasting on a mismatch. The failure this closes is silent: `DELEGATECALL` into an address with no code *succeeds* with empty returndata, so a wrongly-linked deployment would pass its own wiring checks and then do nothing on every library call. (The guard is skipped on Anvil and in dry runs, where the variable is unset.)

`script/DeployBazaar.s.sol` deploys, in order: `BazaarOracle` → `BazaarPairLens` → the `BazaarPair` implementation → `BazaarSequencer` and `BazaarPairTerminator` (constructed against the factory address *predicted* via `vm.computeCreateAddress`) → `BazaarFactory`, then asserts the prediction held. The factory constructor independently re-checks the wiring (`Factory__WiringMismatch`), so a bad prediction cannot deploy a half-wired system.

The sequencer and terminator are pre-deployed against the predicted address because inlining their deployment in the factory constructor would push its initcode past the EIP-3860 limit.

## The genesis UMA identifier

`DeployBazaar.s.sol` passes the factory a `UMA_IDENTIFIER` constant, currently **`ASSERT_TRUTH2`**, and the constructor validates it against UMA's *live* `IdentifierWhitelist` before storing it. A value that is not whitelisted, or is not named `ASSERT_TRUTH…`, reverts the deployment — which is the only acceptable place to discover it, since every `assertTruth` the protocol ever makes would otherwise revert. Note that OOv3's own `defaultIdentifier` constant is `ASSERT_TRUTH`, which UMA has de-whitelisted in favour of the successor on the same oracle, so deriving the value from the oracle is exactly wrong. After deployment the identifier moves only through the [governance track](../protocol/listing.md#the-only-governance-swapping-the-uma-identifier). Mock networks accept any identifier, because the mock whitelist reports everything as supported.

## Environment

| Variable | Used by |
|---|---|
| `ARBITRUM_MAINNET_RPC_URL`, `ARBITRUM_SEPOLIA_RPC_URL`, `BASE_SEPOLIA_RPC_URL` | `foundry.toml` RPC endpoints |
| `ACCOUNT`, `SENDER` | keystore account for `forge script` |
| `ARBISCAN_API_KEY`, `BASESCAN_API_KEY` | contract verification |
| `ANVIL_RPC_URL`, `ANVIL_PRIVATE_KEY`, `ANVIL_WALLET` | local Makefile targets |

## Network support

See [Networks](../reference/networks.md) for chain IDs and external-contract addresses. Note that `BazaarPair` reads Arbitrum's `ArbSys` precompile (`0x64`) for L2 block numbers — the protocol runs only on Arbitrum chains. The Base Sepolia configuration exists solely to exercise the real UMA OOv3 dispute flow, which has no official Arbitrum Sepolia deployment.
