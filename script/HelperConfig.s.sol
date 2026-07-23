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
        } else if (block.chainid == 84532) {
            activeNetworkConfig = getBaseSepoliaConfig();
        } else if (block.chainid == 31337) {
            activeNetworkConfig = getOrCreateAnvilConfig();
        } else {
            revert("Network not supported");
        }
    }

    // -------------------- Arbitrum Mainnet --------------------

    function getArbitrumMainnetConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            pythFeed: 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C,
            usdcContract: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            optimisticOracleV3: 0xa6147867264374F324524E30C02C331cF28aa879,
            name: "Arbitrum-Mainnet"
        });
    }

    // -------------------- Arbitrum Sepolia --------------------
    // Uses real USDC and Pyth on Arbitrum Sepolia, but mocks UMA OOv3
    // since UMA has no official testnet deployment on Arbitrum Sepolia.

    function getOrCreateArbitrumSepoliaConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.optimisticOracleV3 == address(0)) {
            vm.startBroadcast();
            MockOptimisticOracleV3 mockOO = new MockOptimisticOracleV3(0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d, 7200);
            vm.stopBroadcast();

            return NetworkConfig({
                pythFeed: 0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF,
                usdcContract: 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d,
                optimisticOracleV3: address(mockOO),
                name: "Arbitrum-Sepolia"
            });
        } else {
            return activeNetworkConfig;
        }
    }

    // -------------------- Base Sepolia --------------------
    // UMA has an official OOv3 deployment on Base Sepolia,
    // so we can test the full UMA dispute flow here.

    function getBaseSepoliaConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            pythFeed: 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729,
            usdcContract: 0x036CbD53842c5426634e7929541eC2318f3dCF7e,
            optimisticOracleV3: 0x0F7fC5E6482f096380db6158f978167b57388deE,
            name: "Base-Sepolia"
        });
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
