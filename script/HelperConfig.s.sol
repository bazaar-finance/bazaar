// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {MockOptimisticOracleV3} from "../test/mocks/MockOptimisticOracleV3.sol";

contract HelperConfig is Script {
    // if we are on a local anvil, we deploy mocks
    // Otherwise, grab the existing address from the live network

    NetworkConfig public activeNetworkConfig;

    struct NetworkConfig {
        address pythFeed;
        address usdcContract;
        address optimisticOracleV3;
        string name;
    }

    constructor() {
        if (block.chainid == 42161) {
            activeNetworkConfig = getArbitrumMainnetConfig();
        } else if (block.chainid == 421614) {
            activeNetworkConfig = getOrCreateArbitrumSepoliaConfig();
        } else if (block.chainid == 31337) {
            activeNetworkConfig = getOrCreateAnvilConfig();
        } else {
            revert("Network not supported");
        }
    }

    // -------------------- Arbitrum Mainnet --------------------

    /// @dev Every address here is a literal with no on-chain provenance of its own, and each one is
    ///      consumed as an immutable: the factory keeps `usdc` and the OOv3, and BazaarOracle keeps
    ///      the Pyth feed, none with a setter. A wrong entry is therefore not a misconfiguration to
    ///      be corrected but a redeployment of the whole system, so what each slot must hold is
    ///      recorded here and re-checked against its issuer's own published deployment list before a
    ///      mainnet run. DeployBazaar._assertExternalDependencies probes all three at deploy time.
    ///
    ///      - `usdcContract` must be Circle's NATIVE USDC on Arbitrum One, not the bridged USDC.e
    ///        (`0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8`). The two are separate ERC-20s with
    ///        separate liquidity; picking the bridged one would denominate every pair in a token the
    ///        protocol did not intend and could never migrate off. Both happen to carry 6 decimals,
    ///        so the deploy-time decimals probe does not separate them — this is the one entry that
    ///        has to be read character by character.
    ///      - `pythFeed` must be the Pyth Core contract for Arbitrum One from Pyth's own EVM
    ///        contract-address list. Pyth has cut over to a new deployment before; an address that
    ///        was right for a prior release is not evidence about the current one.
    ///      - `optimisticOracleV3` must be UMA's OptimisticOracleV3 for Arbitrum One. UMA's Finder
    ///        is reached through it at runtime rather than configured here, so this address alone
    ///        determines which UMA deployment adjudicates every listing and termination.
    function getArbitrumMainnetConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            pythFeed: 0xe15357fB7ab31E091583b9c4b4135BB2f176f38e,
            usdcContract: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            optimisticOracleV3: 0xa6147867264374F324524E30C02C331cF28aa879,
            name: "Arbitrum-Mainnet"
        });
    }

    // -------------------- Arbitrum Sepolia --------------------
    // Uses real USDC and Pyth on Arbitrum Sepolia, but mocks UMA OOv3
    // since UMA has no official testnet deployment on Arbitrum Sepolia.

    /// @dev Same sourcing rule as the mainnet config: `usdcContract` is the Arbitrum Sepolia test
    ///      USDC and `pythFeed` the Pyth Core contract for that chain, both read from the issuer's
    ///      published list. The mock OOv3 is constructed against the same USDC it will price bonds
    ///      in, so a wrong USDC here surfaces as a broken listing flow on the rehearsal rather than
    ///      on mainnet.
    function getOrCreateArbitrumSepoliaConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.optimisticOracleV3 == address(0)) {
            vm.startBroadcast();
            MockOptimisticOracleV3 mockOO = new MockOptimisticOracleV3(0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d, 7200);
            vm.stopBroadcast();

            return NetworkConfig({
                pythFeed: 0x0B73614636C855Bf23F342F307FB981A3e47f42B,
                usdcContract: 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d,
                optimisticOracleV3: address(mockOO),
                name: "Arbitrum-Sepolia"
            });
        } else {
            return activeNetworkConfig;
        }
    }

    // -------------------- Anvil (local) --------------------
    // If UMA sandbox is deployed, set SANDBOX_OOV3 and SANDBOX_USDC env vars.
    // Otherwise, deploys mocks for everything.

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.pythFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        MockPyth mockPyth = new MockPyth(0, 0);
        MockUSDC mockUSDC = new MockUSDC();
        MockOptimisticOracleV3 mockOO = new MockOptimisticOracleV3(address(mockUSDC), 7200);
        vm.stopBroadcast();

        return NetworkConfig({
            pythFeed: address(mockPyth),
            usdcContract: address(mockUSDC),
            optimisticOracleV3: address(mockOO),
            name: "Anvil"
        });
    }
}
