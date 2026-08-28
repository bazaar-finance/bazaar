# Bazaar

**Permissionless perpetual futures on anything with a price feed — no admin keys, no whitelists, no off-switch.**

Bazaar is a USDC-margined perpetual-futures protocol built for Arbitrum. Any asset with a [Pyth](https://pyth.network) price feed — crypto, equities, FX, indices — can be listed permissionlessly through an [UMA Optimistic Oracle](https://uma.xyz) assertion and traded on an on-chain central limit order book. The book is **fully on-chain and sorted**, and orders match **on arrival**, inside their own creation transaction — price-time priority and fill prices are enforced by the contract itself, with no trusted matcher anywhere in the fill path.

The protocol is immutable: no owner, no pauser, no upgradeable proxies, no governance token. Every privileged action is either fully permissionless, economically bonded, or adjudicated by UMA's optimistic oracle. The single governed parameter — the UMA identifier those assertions are adjudicated under — moves only through a $5,000-bonded assertion, a 2-day public dispute window, and a 14-day activation timelock.

> ⚠️ **Status: pre-audit, work in progress — not yet deployed.** There is no official deployment on any network; do not use with real funds.

## Documentation

**Read the book at [docs.bazaar.finance](https://docs.bazaar.finance/).**

Everything protocol-level — architecture, matching, the risk engine, funding, fees, listing, termination, parameter tables, the contract reference, and role guides for traders, LPs, keepers, and integrators — lives there, built from [`docs/`](docs) and redeployed on every push that touches it. The book is the single source of truth for how the protocol works; this README covers only the repository itself.

## Development

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) and Node.js (for the Pyth SDK dependency).

```bash
git clone --recursive <repo-url> && cd bazaar
npm install          # @pythnetwork/pyth-sdk-solidity
forge build
forge test
```

CI pins Foundry to v1.4.3 and runs `forge fmt --check`, build, and the full test suite on every push; EIP-170 size limits are enforced as a test (`test/unit/ContractSizeTest.t.sol`) over production contracts.

For the full local stack on Anvil — mocked Pyth/UMA/USDC, listing a pair, pushing prices, placing orders — see [Local Development](https://docs.bazaar.finance/guide/quick-start.html) in the book; `make help` lists every target. Deploying the protocol to a real network is covered in [Self-Deployment](https://docs.bazaar.finance/guide/deployment.html).

## Repository layout

```
src/
├── BazaarPair.sol              # Core market: orders, positions, insurance, lifecycle
├── BazaarFactory.sol           # UMA-gated listings, EIP-1167 cloning
├── BazaarOracle.sol            # Pyth adapter + composite feeds
├── BazaarPairTerminator.sol    # Wind-down paths
├── BazaarPairLens.sol          # Read-only views
├── interfaces/
└── libraries/                  # ten DELEGATECALL externals, then inlined helpers
    ├── MatchingEngineLib.sol   # Arrival matching: the walk, insertion, unload
    ├── OrderManagementLib.sol  # Order creation/cancel/cleanup
    ├── CollateralLib.sol       # Deposits/withdrawals incl. terminal modes
    ├── LiquidationLib.sol      # Bankruptcy pricing, vault aggregation
    ├── AdlLib.sol              # Dutch-auction auto-deleveraging
    ├── InsuranceVaultLib.sol   # LP shares, cooldowns, rate limits
    ├── RiskParamsLib.sol       # Dynamic IMR/MMR + fee curves
    ├── FundingLib.sol          # Mark EMA + funding index
    ├── TerminationLib.sol      # Settlement waterfall
    ├── MetaTxLib.sol           # EIP-712 meta-transactions
    ├── OrderBookLib.sol        # Sorted doubly-linked book lists (insert/unlink)
    ├── BucketLib.sol           # Position solvency math
    ├── VaultHealthLib.sol      # ADL/termination triggers
    ├── MmrSampleLib.sol        # 24h-lagged MMR ring buffer
    ├── BazaarMathLib.sol       # Fixed-point + effective-price helpers
    └── BazaarTypes.sol         # Structs, enums, protocol constants
script/                         # DeployLibraries + DeployBazaar + network config
test/
├── unit/                       # 24 test files: per-library and per-mechanism
└── integration/                # 31 test files: end-to-end, incl. zero-sum invariant
```

## Security

- **Unaudited and not deployed.** This codebase has not undergone a professional audit, and there is no official deployment on any network.
- No admin keys: there is nothing to compromise, but also no one who can pause a bad deployment — the [termination paths](https://docs.bazaar.finance/protocol/termination.html) are the only brakes.
- **Reporting a vulnerability:** please use GitHub's private vulnerability reporting — go to the [Security tab](../../security/advisories/new) and select *Report a vulnerability*. Do not open a public issue for security findings.
- There is no bug-bounty program at this stage. Valid findings are credited to the reporter in the published advisory. A retroactive reward may be considered for significant findings once the project is funded, but none is promised or guaranteed.
- What is in and out of scope, and the posture a report should assume: [SECURITY.md](SECURITY.md). Full posture and testing detail: [Security & Status](https://docs.bazaar.finance/security.html) in the book.

## License

[AGPL-3.0-only](LICENSE). If you fork this protocol and run it as a service, you must open-source your modifications under the same license — including the network-use provision of §13.
