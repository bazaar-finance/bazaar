// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {BazaarFactory} from "../src/BazaarFactory.sol";
import {BazaarPair} from "../src/BazaarPair.sol";
import {BazaarOracle} from "../src/BazaarOracle.sol";
import {BazaarPairLens} from "../src/BazaarPairLens.sol";
import {BazaarSequencer} from "../src/BazaarSequencer.sol";
import {BazaarPairTerminator} from "../src/BazaarPairTerminator.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

/// @notice Step 2: Deploy core Bazaar contracts.
///         Requires external libraries to be deployed first (see DeployLibraries.s.sol)
///         and their addresses configured in foundry.toml [profile.default.libraries].
contract DeployBazaar is Script {
    function run() external returns (BazaarFactory factory, HelperConfig helperConfig) {
        return deploy(address(0));
    }

    function deploy(address bugBountyAddress) public returns (BazaarFactory factory, HelperConfig helperConfig) {
        helperConfig = new HelperConfig();
        (address pythFeed, address usdcContract, address optimisticOracleV3, string memory networkName) =
            helperConfig.activeNetworkConfig();

        console.log("----------------------------------------------------");
        console.log("Deploying Bazaar to:", networkName);
        console.log("  USDC:              ", usdcContract);
        console.log("  Pyth:              ", pythFeed);
        console.log("  OptimisticOracleV3:", optimisticOracleV3);
        console.log("----------------------------------------------------");

        vm.startBroadcast();

        if (bugBountyAddress == address(0)) {
            bugBountyAddress = msg.sender;
        }

        // 1. Deploy contracts that don't depend on the factory
        BazaarOracle bazaarOracle = new BazaarOracle(pythFeed);
        console.log("BazaarOracle:            ", address(bazaarOracle));

        BazaarPairLens bazaarLens = new BazaarPairLens();
        console.log("BazaarPairLens:          ", address(bazaarLens));

        BazaarPair pairImplementation = new BazaarPair();
        console.log("BazaarPair implementation:", address(pairImplementation));

        // 2. Deploy BazaarSequencer + BazaarPairTerminator against the CREATE-predicted factory
        //    address (their `factory` fields are immutable). Deploying them inside the factory
        //    constructor would push its initcode past the EIP-3860 limit. The factory constructor
        //    re-checks the wiring on-chain (Factory__WiringMismatch), so a wrong prediction
        //    cannot deploy a mis-wired system — it just reverts.
        (, address broadcaster,) = vm.readCallers();
        address predictedFactory = vm.computeCreateAddress(broadcaster, vm.getNonce(broadcaster) + 2);

        BazaarSequencer sequencer = new BazaarSequencer(usdcContract, predictedFactory);
        console.log("BazaarSequencer:         ", address(sequencer));

        BazaarPairTerminator pairTerminator = new BazaarPairTerminator(predictedFactory);
        console.log("BazaarPairTerminator:    ", address(pairTerminator));

        // 3. Deploy BazaarFactory
        factory = new BazaarFactory(
            usdcContract,
            address(bazaarOracle),
            address(bazaarLens),
            bugBountyAddress,
            optimisticOracleV3,
            address(pairImplementation),
            address(sequencer),
            address(pairTerminator)
        );
        require(address(factory) == predictedFactory, "Factory address prediction mismatch");
        console.log("BazaarFactory:           ", address(factory));

        vm.stopBroadcast();

        console.log("----------------------------------------------------");
        console.log("Deployment complete!");
        console.log("----------------------------------------------------");
    }
}
