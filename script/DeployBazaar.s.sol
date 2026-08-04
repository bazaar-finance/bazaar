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
///         Requires external libraries to be deployed first (see DeployLibraries.s.sol); their
///         `--libraries` flags come from `deployments/<chainid>/libraries.args`, which the Makefile
///         targets splat onto the forge command line.
contract DeployBazaar is Script {
    /// @dev The Makefile's live-network targets set `EXPECTED_CHAIN_ID` to the chain the deploy is
    ///      meant for, and `_assertExpectedChain` refuses to run anywhere else.
    ///
    ///      The guard exists because the library link flags are chosen by the make target, not by
    ///      the chain the RPC actually serves: `deploy-arb-mainnet` always splats
    ///      `deployments/42161/libraries.args`. If `ARBITRUM_MAINNET_RPC_URL` resolves to a
    ///      different chain, those addresses hold no code there — and DELEGATECALL into an
    ///      account with no code succeeds and returns empty data rather than reverting. The
    ///      factory would deploy cleanly, pass its own wiring checks, and every call routed
    ///      through a linked library would silently do nothing. Nothing downstream detects that,
    ///      so the chain has to be pinned before the first broadcast.
    ///
    ///      Left unset for anvil, dry runs and the test suite, where the check is skipped.
    function _assertExpectedChain() internal view {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        if (expected == 0) return;
        require(
            block.chainid == expected,
            string.concat(
                "Chain id mismatch: EXPECTED_CHAIN_ID=",
                vm.toString(expected),
                " but the RPC serves chain ",
                vm.toString(block.chainid),
                " -- the linked library addresses do not exist on that chain."
            )
        );
    }

    /// @dev The genesis UMA identifier. The factory constructor validates it against UMA's LIVE
    ///      IdentifierWhitelist and reverts if absent — so a wrong value fails at deploy time, not
    ///      as a bricked protocol later. Mock networks accept any identifier (mock whitelist
    ///      defaults to supported).
    ///
    ///      "ASSERT_TRUTH2" is the live identifier for OOv3 truth assertions on both Arbitrum and
    ///      mainnet. OOv3's own `defaultIdentifier` constant ("ASSERT_TRUTH") is NOT whitelisted —
    ///      UMA deprecated the original and whitelisted the successor on the same oracle
    ///      deployment. That is why the identifier is a governed, whitelist-validated parameter
    ///      here rather than derived from `oo.defaultIdentifier()`, which points at the dead one.
    bytes32 public constant UMA_IDENTIFIER = "ASSERT_TRUTH2";

    function run() external returns (BazaarFactory factory, HelperConfig helperConfig) {
        return deploy(address(0));
    }

    function deploy(address bugBountyAddress) public returns (BazaarFactory factory, HelperConfig helperConfig) {
        _assertExpectedChain();

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
            address(pairTerminator),
            UMA_IDENTIFIER
        );
        require(address(factory) == predictedFactory, "Factory address prediction mismatch");
        console.log("BazaarFactory:           ", address(factory));

        vm.stopBroadcast();

        console.log("----------------------------------------------------");
        console.log("Deployment complete!");
        console.log("----------------------------------------------------");
    }
}
