// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {LinkedLibraries} from "./LinkedLibraries.sol";

/// @notice Step 1 of the two-step deployment: deploys every external library that BazaarPair,
///         BazaarFactory or BazaarPairTerminator carries a link reference for, then writes the
///         `--libraries` flags for them to `deployments/<chainid>/libraries.args`, except on a
///         dry run.
/// @dev    The library list, the flag format and the record path all come from `LinkedLibraries`,
///         which step 2 shares: it reads the record for the chain it is deploying to, refuses to
///         run when the record is absent, and checks that every recorded address still holds the
///         code it links against, so a record from an earlier library build cannot be linked
///         into a later pair implementation.
///
///         The libraries link each other: the ones that call RiskParamsLib's public functions
///         carry its link placeholder in their own bytecode and cannot be deployed until it has
///         an address. Forge resolves such placeholders only from `--libraries` flags, which are
///         what this step produces, so the script resolves them itself: each library's creation
///         code is read from its raw artifact, the placeholders of the libraries already deployed
///         in this run are replaced by their addresses, and a library whose placeholders are not
///         all resolvable yet waits for the next pass. Linking from this run's own addresses is
///         what keeps the set consistent: every dependent delegates into the RiskParamsLib this
///         run records, never into one from an earlier deployment.
///
///         Forge executes the script, file writes included, before it broadcasts anything, and a
///         run without `--broadcast` stops there. A dry run's addresses are therefore simulated,
///         and writing them would overwrite the committed record of the live set with addresses
///         that hold no code. It prints the flags and leaves the record alone. A broadcast run
///         writes its record before its transactions land, so an interrupted broadcast leaves
///         addresses some of which hold no code yet. Step 2's code check refuses such a record;
///         `forge script --resume` sends the run's remaining transactions at their recorded
///         nonces without executing the script again, which makes it valid.
contract DeployLibraries is Script, LinkedLibraries {
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

    /// @dev Deploys the set in dependency order: each pass deploys every library whose link
    ///      placeholders all name libraries deployed in an earlier pass, or none. A pass that
    ///      deploys nothing means a remaining library links one outside `_libNames()`, and the
    ///      run aborts there rather than deploy code that would delegate into an empty account.
    function _deployAll() internal returns (address[12] memory addrs) {
        string[12] memory names = _libNames();
        bool[12] memory deployed;
        uint256 left = names.length;
        while (left != 0) {
            uint256 before = left;
            for (uint256 i; i < names.length; ++i) {
                if (deployed[i]) continue;
                (string memory object, bool resolved) =
                    _linkCode(_artifactObject(names[i], false), names, addrs, deployed);
                if (!resolved) continue;
                addrs[i] = _create(vm.parseBytes(object), names[i]);
                deployed[i] = true;
                --left;
            }
            require(left < before, "a remaining library links one outside _libNames()");
        }
    }

    function _create(bytes memory bytecode, string memory name) internal returns (address addr) {
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(addr != address(0), string.concat("Failed to deploy ", name));
    }

    function run() external {
        _assertExpectedChain();

        vm.startBroadcast();
        address[12] memory addrs = _deployAll();
        vm.stopBroadcast();

        // One flag per library, space-separated so the file can be splatted straight onto a forge
        // command line.
        string[12] memory names = _libNames();
        string memory args;
        for (uint256 i; i < names.length; ++i) {
            args = string.concat(args, i == 0 ? "" : " ", _libLinkFlag(names[i], addrs[i]));
        }

        string memory outPath = _libArgsPath(block.chainid);
        bool dryRun = vm.isContext(VmSafe.ForgeContext.ScriptDryRun);
        if (!dryRun) {
            vm.createDir(_libArgsDir(block.chainid), true);
            vm.writeFile(outPath, args);
        }

        console.log("----------------------------------------------------");
        if (dryRun) console.log("External libraries simulated for chain:", block.chainid);
        else console.log("External libraries deployed on chain:", block.chainid);
        for (uint256 i; i < names.length; ++i) {
            console.log("  %s: %s", names[i], addrs[i]);
        }
        console.log("----------------------------------------------------");
        if (dryRun) {
            console.log("Dry run: nothing was broadcast, so the record was NOT written:", outPath);
            console.log("Link flags this run would have recorded:");
            console.log(args);
        } else {
            console.log("Link flags written to:", outPath);
            console.log("Step 2 reads this file automatically:");
            console.log("  make deploy-arb-sepolia   (or make deploy-arb-mainnet)");
        }
        console.log("----------------------------------------------------");
    }
}
