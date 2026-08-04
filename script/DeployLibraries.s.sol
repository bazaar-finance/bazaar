// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/// @notice Step 1 of the two-step deployment: deploys every external library that BazaarPair
///         carries a link reference for, then writes the `--libraries` flags for them to
///         `deployments/<chainid>/libraries.args`.
/// @dev    The output path is keyed by chain id because a library address is only meaningful on
///         the chain it was deployed to. A single shared list would let a rehearsal network's
///         addresses be linked into a production build, where those addresses hold no code and
///         every DELEGATECALL from the pair would land on an empty account. Step 2 reads the file
///         for the chain it is deploying to and refuses to run when it is absent.
contract DeployLibraries is Script {
    /// @notice Every externally-linked library, in one list.
    /// @dev    This list is the only place a library is named. The artifact id, the link path and
    ///         the emitted flag are all derived from it, so a library cannot be deployed but left
    ///         out of the link flags (or vice versa). A new external library needs one edit here
    ///         and a matching bump of the array length.
    function _libNames() internal pure returns (string[10] memory names) {
        names[0] = "InsuranceVaultLib";
        names[1] = "LiquidationLib";
        names[2] = "OrderManagementLib";
        names[3] = "AdlLib";
        names[4] = "MatchingEngineLib";
        names[5] = "CollateralLib";
        names[6] = "RiskParamsLib";
        names[7] = "FundingLib";
        names[8] = "TerminationLib";
        names[9] = "MetaTxLib";
    }

    function _deployLib(string memory artifact) internal returns (address addr) {
        bytes memory bytecode = vm.getCode(artifact);
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(addr != address(0), string.concat("Failed to deploy ", artifact));
    }

    /// @dev The Makefile's live-network targets set `EXPECTED_CHAIN_ID` to the chain the deploy is
    ///      meant for. Without it, an `--rpc-url` alias resolving to the wrong chain deploys a full
    ///      set of libraries there and records them under that chain's `deployments/` directory —
    ///      internally consistent, silently useless, and paid for in real gas. Step 2 applies the
    ///      same guard so the two halves cannot land on different chains.
    ///
    ///      Left unset for anvil and dry runs, where the check is skipped.
    function _assertExpectedChain() internal view {
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(0));
        if (expected == 0) return;
        require(
            block.chainid == expected,
            string.concat(
                "Chain id mismatch: EXPECTED_CHAIN_ID=",
                vm.toString(expected),
                " but the RPC serves chain ",
                vm.toString(block.chainid)
            )
        );
    }

    function run() external {
        _assertExpectedChain();

        string[10] memory names = _libNames();
        address[10] memory addrs;

        vm.startBroadcast();
        for (uint256 i; i < names.length; ++i) {
            addrs[i] = _deployLib(string.concat(names[i], ".sol:", names[i]));
        }
        vm.stopBroadcast();

        // One flag per library: `--libraries src/libraries/Foo.sol:Foo:0xADDR`, space-separated so
        // the file can be splatted straight onto a forge command line.
        string memory args;
        for (uint256 i; i < names.length; ++i) {
            args = string.concat(
                args,
                i == 0 ? "" : " ",
                "--libraries src/libraries/",
                names[i],
                ".sol:",
                names[i],
                ":",
                vm.toString(addrs[i])
            );
        }

        string memory dir = string.concat("deployments/", vm.toString(block.chainid));
        vm.createDir(dir, true);
        string memory outPath = string.concat(dir, "/libraries.args");
        vm.writeFile(outPath, args);

        console.log("----------------------------------------------------");
        console.log("External libraries deployed on chain:", block.chainid);
        for (uint256 i; i < names.length; ++i) {
            console.log("  %s: %s", names[i], addrs[i]);
        }
        console.log("----------------------------------------------------");
        console.log("Link flags written to:", outPath);
        console.log("Step 2 reads this file automatically:");
        console.log("  make deploy-arb-sepolia   (or make deploy-arb-mainnet)");
        console.log("----------------------------------------------------");
    }
}
