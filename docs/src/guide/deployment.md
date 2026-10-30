# Self-Deployment

> **You do not need this page to use Bazaar.** The canonical deployment's addresses are in [Deployments](../reference/networks.md), and [Using Bazaar](using-bazaar.md) covers trading, LPing, running keepers, and integrating against it. This page is for protocol developers and for anyone standing up an independent deployment — in which case note the [AGPL-3.0 network clause](../license.md): a fork operated as a service must publish its modified source.

Deployment is **two-step** because the heavy logic lives in externally deployed libraries that are linked by address (see [Architecture](../protocol/architecture.md#code-size-strategy)).

## Step 1 — deploy the external libraries

```bash
make deploy-libs-arb-sepolia    # or: deploy-libs-arb-mainnet (asks for confirmation)
```

The core contracts carry link references for **twelve** DELEGATECALL libraries: `BazaarPair` for eleven — `InsuranceVaultLib`, `LiquidationLib`, `OrderManagementLib`, `AdlLib`, `MatchingEngineLib`, `CollateralLib`, `RiskParamsLib`, `FundingLib`, `TerminationLib`, `MetaTxLib`, `VaultHealthLib` — and `BazaarFactory` and `BazaarPairTerminator` for `ClaimTextLib`, which holds the static text of the UMA claims they assert. Every one of them must be deployed and linked before the pair implementation, the factory or the terminator can go out.

The script deploys all twelve and records their `--libraries` flags in `deployments/<chainid>/libraries.args`. Nothing is pasted by hand, and nothing is written to `foundry.toml`: `libraries` there is a single global key with no per-network scoping, so one shared list would let a rehearsal network's addresses be linked into a production build — where they hold no code, and every `DELEGATECALL` from the pair would land on an empty account. Keying the record by chain id makes that unrepresentable.

Only a broadcast writes the record. `forge` executes a script, file writes included, before it broadcasts anything, so a dry run (the same command without `--broadcast`) produces addresses that were only simulated; writing them would overwrite the committed record of the live library set with addresses that hold no code. A dry run therefore prints the flags it would have recorded and leaves the file alone. A broadcast run writes the record before its transactions land, so a broadcast interrupted partway leaves a record naming some addresses that hold no code yet: step 2 refuses it. Resuming that broadcast (`forge script --resume`) sends the remaining transactions of the same run at their recorded nonces without executing the script again, which makes the record valid; a fresh step 1 instead deploys a new set and records that.

Five of the twelve — `InsuranceVaultLib`, `AdlLib`, `MatchingEngineLib`, `TerminationLib` and `VaultHealthLib` — call `RiskParamsLib`'s public functions, so their own bytecode carries a link placeholder for its address. `forge` resolves such placeholders only from `--libraries` flags, which are what step 1 produces, so the script resolves them itself: it reads each library's creation code from its raw artifact under `out/` (the one directory `foundry.toml` lets it read besides the record), replaces the placeholders of the libraries already deployed in the run with their addresses, and holds a library back until everything it links against has an address. The dependents are therefore linked to the `RiskParamsLib` of the same run — the one the record names — and never to an earlier deployment's; a placeholder naming a library outside the list aborts the run.

The library list lives in one place, `_libNames()` in `script/LinkedLibraries.sol`, which both steps share; the artifact id and path, the link placeholder, the link target, the emitted flag and the record path are all derived from it, so a library cannot be deployed but left out of the link flags, or recorded but left unchecked by step 2. Adding a library to the list changes the record's shape: step 2 requires exactly one flag per listed library, so a chain's existing `deployments/<chainid>/libraries.args` is refused until step 1 is re-run there, which deploys the whole set afresh. Real networks' records are committed as deployment provenance; the local Anvil chain's (`deployments/31337/`) is gitignored as throwaway.

## Step 2 — deploy the core

```bash
make deploy-arb-sepolia    # or: deploy-arb-mainnet (asks for confirmation)
```

The target passes that chain's recorded flags to `forge` and refuses to run if the file for its chain is missing, so step 2 cannot silently produce an unlinked or cross-linked deployment.

The record is a committed file, so step 2 can run long after step 1, with any number of library edits in between — and `forge` links by library *name*, not by code. Before its first broadcast the script therefore reads the record back and requires every library in the list to be recorded exactly once, at an address whose runtime code matches the artifact this build links against — read from `out/` as step 1 reads it, with any link placeholder the build left resolved to the recorded addresses, so the five dependents must hold the `RiskParamsLib` the record names in their link slots and a record assembled from two library deployments is refused like a stale one. Without that, a stale record would link the new pair implementation to old library code (missing a fix, or reading struct offsets the pair no longer uses), and a record missing a library would let `forge` deploy that one itself, unrecorded; neither is caught downstream, because nothing in the deployment calls a library, and the linked set is immutable. Two parts of the deployed code legitimately differ from the artifact and are set aside before comparing: the CBOR metadata trailer (`settings.libraries` is part of every contract's metadata, so a library compiled by step 1 with no link flags and by step 2 with all of them differs in its metadata hash even when it links nothing) and the library's own address, which the deployed code embeds for call protection where the artifact holds zeros. A missing, duplicate, malformed, code-less or stale entry aborts the run naming the library; the remedy is always to re-run step 1.

The per-chain file only helps if the RPC alias actually serves the chain the target names — the args path is chosen by the make target, not read off the network. Both scripts therefore assert `block.chainid` against the `EXPECTED_CHAIN_ID` the target passes and abort before broadcasting on a mismatch, and step 2's code check is gated on the same variable, since the live targets are the ones that splat the record. The failure this closes surfaces late rather than loudly: nothing in the deployment calls a library, so a wrongly-linked factory deploys cleanly and passes its wiring checks, and only the first pair call that reaches a library reverts, against the empty account. (The guards are skipped on Anvil and in dry runs, where the variable is unset; there `forge` deploys the libraries itself.)

`script/DeployBazaar.s.sol` deploys, in order: `BazaarOracle` → the `BazaarPair` implementation → `BazaarPairLens` → `BazaarPairTerminator` (the lens and the terminator each constructed against the factory address *predicted* via `vm.computeCreateAddress`, two nonces past the lens's) → `BazaarFactory`, then asserts the prediction held. The factory constructor independently re-checks both wirings (`Factory__WiringMismatch`), so a bad prediction cannot deploy a half-wired system.

The lens and the terminator are pre-deployed against the predicted address because inlining their deployment in the factory constructor would push the factory's initcode past the EIP-3860 limit.

## The bug-bounty recipient

`BUG_BOUNTY_ADDRESS` must be set before deploying to any chain but Anvil; the script aborts before the first broadcast if it is missing, and prints the resolved address in the banner alongside USDC, Pyth and the OOv3. It receives 1% (`BUG_BOUNTY_TAX_BP`) of the integrator and insurance fee streams on every fill. The factory holds it `immutable` and copies it into every pair at listing, so there is no setter and no governance path — changing it means redeploying the factory and re-listing every pair. Anvil keeps an implicit default of the deploying account, since a local chain has no revenue to misdirect.

## The genesis UMA identifier

`DeployBazaar.s.sol` passes the factory a `UMA_IDENTIFIER` constant, currently **`ASSERT_TRUTH2`**, and the constructor validates it against UMA's *live* `IdentifierWhitelist` before storing it. A value that is not whitelisted, or is not named `ASSERT_TRUTH…`, reverts the deployment — which is the only acceptable place to discover it, since every `assertTruth` the protocol ever makes would otherwise revert. Note that OOv3's own `defaultIdentifier` constant is `ASSERT_TRUTH`, which UMA has de-whitelisted in favour of the successor on the same oracle, so deriving the value from the oracle is exactly wrong. After deployment the identifier moves only through the [governance track](../protocol/listing.md#the-only-governance-swapping-the-uma-identifier). Mock networks pass the whitelist check for any identifier, because the mock whitelist reports everything as supported; the `ASSERT_TRUTH…` naming rule still applies there.

## Environment

| Variable | Used by |
|---|---|
| `ARBITRUM_MAINNET_RPC_URL`, `ARBITRUM_SEPOLIA_RPC_URL` | `foundry.toml` RPC endpoints |
| `ACCOUNT`, `SENDER` | keystore account for `forge script` |
| `BUG_BOUNTY_ADDRESS` | bug-bounty fee recipient — **required on live chains** |
| `ARBISCAN_API_KEY` | contract verification |
| `ANVIL_RPC_URL`, `ANVIL_PRIVATE_KEY`, `ANVIL_WALLET` | local Makefile targets |

## Network support

See [Networks](../reference/networks.md) for chain IDs and external-contract addresses. Note that `BazaarPair` reads Arbitrum's `ArbSys` precompile (`0x64`) for L2 block numbers — the protocol runs only on Arbitrum chains. UMA has no official OOv3 deployment on Arbitrum Sepolia, so the testnet configuration deploys a mock; the real UMA dispute flow can only be exercised on a chain with an official OOv3 deployment.
