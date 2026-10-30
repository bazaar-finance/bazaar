// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {BazaarFactory} from "../src/BazaarFactory.sol";
import {BazaarPair} from "../src/BazaarPair.sol";
import {BazaarOracle} from "../src/BazaarOracle.sol";
import {BazaarPairLens} from "../src/BazaarPairLens.sol";
import {BazaarPairTerminator} from "../src/BazaarPairTerminator.sol";
import {BazaarTypes} from "../src/libraries/BazaarTypes.sol";
import {IERC20Minimal, IOptimisticOracleV3} from "../src/interfaces/IUmaOptimisticOracleV3.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {LinkedLibraries} from "./LinkedLibraries.sol";

/// @notice Step 2: Deploy core Bazaar contracts.
///         Requires external libraries to be deployed first (see DeployLibraries.s.sol); their
///         `--libraries` flags come from `deployments/<chainid>/libraries.args`, which the Makefile
///         targets splat onto the forge command line. Before broadcasting, the script reads that
///         record back and checks that every recorded address holds the code this build links
///         against.
contract DeployBazaar is Script, LinkedLibraries {
    /// @dev The Makefile's live-network targets set `EXPECTED_CHAIN_ID` to the chain the deploy is
    ///      meant for, and `_assertExpectedChain` refuses to run anywhere else.
    ///
    ///      The guard exists because the library link flags are chosen by the make target, not by
    ///      the chain the RPC actually serves: `deploy-arb-mainnet` always splats
    ///      `deployments/42161/libraries.args`. If `ARBITRUM_MAINNET_RPC_URL` resolves to a
    ///      different chain, those addresses hold no code there. Nothing in the deployment itself
    ///      calls a library, so the factory would deploy cleanly and pass its own wiring checks;
    ///      the breakage would show only on the first pair call that reaches one, which reverts
    ///      against the empty account. The linked set is immutable, so the only remedy would be a
    ///      full redeploy; the chain is pinned before the first broadcast instead.
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

    /// @dev Checks, before the first broadcast, that this chain's `libraries.args` names every
    ///      library in `_libNames()` exactly once and that each recorded address holds the runtime
    ///      code of the artifact this build links against.
    ///
    ///      The record is a committed file that step 1 wrote, so step 2 can run long after it,
    ///      with any number of library edits in between. forge links by library name, not by
    ///      code: a stale record links the new pair implementation to the old library code, which
    ///      may lack a fix or read struct offsets the pair no longer uses, and a record missing a
    ///      library makes forge deploy that one itself, unrecorded. Neither is caught downstream —
    ///      nothing in the deployment calls a library, so the factory deploys cleanly and passes
    ///      its own wiring checks — and the linked set is immutable, so the remedy would be a full
    ///      redeploy and re-listing. An address with no code (an interrupted step 1) fails here
    ///      too, rather than on the first pair call.
    ///
    ///      Gated on `EXPECTED_CHAIN_ID` like the chain guard: the live targets are the ones that
    ///      splat the record, while the local target and the test suite let forge deploy the
    ///      libraries itself and have no record to check.
    ///
    ///      The code expected at each address is the library's artifact, read from `out/` as
    ///      step 1 reads it, with any link placeholder the build left resolved to the recorded
    ///      addresses (`_linkedRuntimeCode`): the five libraries that call RiskParamsLib must
    ///      therefore hold the RiskParamsLib the record names in their link slots, so a record
    ///      assembled from two library deployments fails as a stale one does.
    ///
    ///      Two parts of the on-chain code legitimately differ from the artifact and are
    ///      normalised before hashing. The CBOR metadata trailer: `settings.libraries` is part of
    ///      every contract's metadata, so a library compiled by step 1 (no link flags) and the
    ///      same library compiled by step 2 (all of them) differ in their metadata hash even when
    ///      the library links nothing; the trailer is dropped from both sides. The library's own
    ///      address: the runtime code embeds it for call protection where the artifact holds
    ///      zeros, so every occurrence of the recorded address is zeroed. A copy of the right code
    ///      at an address other than the one it embeds therefore fails the check, which is
    ///      correct: its call protection would reject every DELEGATECALL.
    function _assertLinkedLibraries() internal view {
        if (vm.envOr("EXPECTED_CHAIN_ID", uint256(0)) == 0) return;
        string memory path = _libArgsPath(block.chainid);
        require(vm.exists(path), string.concat(path, " not found -- run step 1 (DeployLibraries) on this chain first"));
        _verifyLinkRecord(vm.readFile(path));
    }

    /// @dev `record` is the file body step 1 writes: one `--libraries <target>:<address>` flag per
    ///      library, space-separated. The flag count must equal the list length and every listed
    ///      library must be found, which together make the record and the list a bijection: a
    ///      duplicate entry displaces another library, which is then reported as missing.
    function _verifyLinkRecord(string memory record) internal view {
        string[12] memory names = _libNames();
        string[] memory tokens = vm.split(vm.trim(record), " ");
        require(
            tokens.length == 2 * names.length,
            "libraries.args: expected exactly one --libraries flag per linked library"
        );

        string[] memory recordedNames = new string[](names.length);
        address[] memory recordedAddrs = new address[](names.length);
        for (uint256 i; i < names.length; ++i) {
            string memory target = tokens[2 * i + 1];
            require(_eq(tokens[2 * i], "--libraries"), string.concat("libraries.args: malformed flag: ", tokens[2 * i]));
            string[] memory parts = vm.split(target, ":");
            require(parts.length == 3, string.concat("libraries.args: malformed link target: ", target));
            require(
                _eq(string.concat(parts[0], ":", parts[1]), _libLinkTarget(parts[1])),
                string.concat("libraries.args: link target is not a src/libraries library: ", target)
            );
            recordedNames[i] = parts[1];
            recordedAddrs[i] = vm.parseAddress(parts[2]);
        }

        // Every address is resolved before any code is checked: a dependent's expected code is
        // linked against the whole recorded set.
        address[12] memory at;
        for (uint256 i; i < names.length; ++i) {
            uint256 j;
            while (j < names.length && !_eq(recordedNames[j], names[i])) ++j;
            require(j < names.length, string.concat("libraries.args: no entry for ", names[i], " -- re-run step 1"));
            at[i] = recordedAddrs[j];
        }
        for (uint256 i; i < names.length; ++i) {
            _assertLibraryCode(names[i], at[i], _linkedRuntimeCode(names[i], names, at));
        }
    }

    /// @dev `addr` must hold `expectedCode`, the runtime code of `name`'s artifact linked against
    ///      the record, up to the two normalisations `_assertLinkedLibraries` describes.
    function _assertLibraryCode(string memory name, address addr, bytes memory expectedCode) internal view {
        string memory where = string.concat(name, " at ", vm.toString(addr));
        bytes memory onChain = addr.code;
        require(
            onChain.length != 0,
            string.concat(where, " holds no code on chain ", vm.toString(block.chainid), " -- re-run step 1")
        );
        bytes32 expected = keccak256(_stripMetadata(expectedCode));
        bytes32 actual = keccak256(_maskSelfAddress(_stripMetadata(onChain), addr));
        require(
            actual == expected,
            string.concat(where, " does not hold the code this build links against -- re-run step 1")
        );
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @dev Probes the three external dependencies HelperConfig hands over, before the first
    ///      broadcast. All three are consumed as immutables — `usdc` and the OOv3 by the factory,
    ///      the Pyth feed by BazaarOracle — so a wrong address is corrected only by redeploying the
    ///      system, and almost nothing downstream reads back as wrong: BazaarOracle rejects only
    ///      `address(0)`, and the factory's identifier probe is a shape check that excludes a dead
    ///      OOv3 rather than a live-but-wrong one.
    ///
    ///      These probes cannot catch a wrong-but-live address of the right shape — only reading
    ///      the literals against their issuer's deployment list does that, which is why
    ///      HelperConfig records what each slot must hold. What they do catch is the failure that
    ///      actually happens: a typo, an address copied from the wrong chain's table, an EOA, or the
    ///      same address pasted into two slots. Each of those produces either no code at all or a
    ///      contract without the selector, and both fail here rather than four broadcasts later.
    ///
    ///      The decimals check is the load-bearing one. The protocol books in BAZAAR_SCALE and
    ///      settles in USDC, converting on every deposit, withdrawal and fee; a token with any other
    ///      precision would not revert anywhere — it would silently mis-scale every balance in the
    ///      system by the ratio between them. Derived from USDC_EXPONENT so the check tracks the
    ///      constant the conversions are written against rather than restating it.
    ///
    ///      Runs on every chain including anvil, where the mocks satisfy it: a guard that only
    ///      executes on the one run nobody rehearses is a guard nobody has tested.
    function _assertExternalDependencies(address pythFeed, address usdcContract, address optimisticOracleV3)
        internal
        view
    {
        require(pythFeed.code.length != 0, "Pyth address holds no code on this chain");
        require(usdcContract.code.length != 0, "USDC address holds no code on this chain");
        require(optimisticOracleV3.code.length != 0, "OptimisticOracleV3 address holds no code on this chain");
        require(
            pythFeed != usdcContract && pythFeed != optimisticOracleV3 && usdcContract != optimisticOracleV3,
            "Pyth / USDC / OptimisticOracleV3 must be three distinct addresses"
        );

        uint8 expectedDecimals = uint8(uint32(-BazaarTypes.USDC_EXPONENT));
        require(
            IERC20Minimal(usdcContract).decimals() == expectedDecimals,
            "USDC decimals do not match USDC_EXPONENT -- every BAZAAR_SCALE conversion would mis-scale"
        );

        // Each call is its own probe: the selector has to exist and return a decodable value, which
        // an EOA or an unrelated contract cannot do. Both are functions the protocol itself depends
        // on — getMinimumBond is what the factory quotes every listing bond from, getUpdateFee what
        // BazaarOracle pays Pyth through — so the probe exercises the same surface the deployment
        // will. getMinimumBond is asked about the USDC resolved above, which checks the two
        // addresses as a pair rather than individually. The empty array is priced at zero by any
        // implementation; the return value carries no information and the call is the whole test.
        IOptimisticOracleV3(optimisticOracleV3).getMinimumBond(usdcContract);
        IPyth(pythFeed).getUpdateFee(new bytes[](0));
    }

    /// @dev The genesis UMA identifier. The factory constructor validates it against UMA's LIVE
    ///      IdentifierWhitelist and reverts if absent — so a wrong value fails at deploy time, not
    ///      as a bricked protocol later. On mock networks the whitelist check passes for any
    ///      identifier (the mock whitelist reports everything as supported), but the factory's
    ///      ASSERT_TRUTH-prefix rule still applies.
    ///
    ///      "ASSERT_TRUTH2" is the live identifier for OOv3 truth assertions on both Arbitrum and
    ///      mainnet. OOv3's own `defaultIdentifier` constant ("ASSERT_TRUTH") is NOT whitelisted —
    ///      UMA deprecated the original and whitelisted the successor on the same oracle
    ///      deployment. That is why the identifier is a governed, whitelist-validated parameter
    ///      here rather than derived from `oo.defaultIdentifier()`, which points at the dead one.
    bytes32 public constant UMA_IDENTIFIER = "ASSERT_TRUTH2";

    /// @dev Recipient of the bug-bounty skim: `BUG_BOUNTY_TAX_BP` (1%) of the integrator and
    ///      insurance fee streams, on every fill, for the life of the protocol. The factory holds
    ///      it `immutable` and copies it into every pair at listing, so there is no setter and no
    ///      governance path — correcting a wrong value means redeploying the factory and re-listing
    ///      every pair.
    ///
    ///      That permanence is why the address is required rather than defaulted. A deployment
    ///      signer is a hot key chosen for convenience; letting it become the one address in the
    ///      system that can never be rotated assigns a revenue stream by accident, and silently,
    ///      since nothing downstream reads back as wrong.
    ///
    ///      Anvil keeps the implicit default: a throwaway chain has no revenue to misdirect, and
    ///      the local targets have to stay runnable with no configuration.
    function _resolveBugBountyRecipient() internal view returns (address) {
        address configured = vm.envOr("BUG_BOUNTY_ADDRESS", address(0));
        if (configured != address(0)) return configured;
        require(
            block.chainid == 31337,
            "BUG_BOUNTY_ADDRESS is unset. It is immutable in the factory and copied into every pair,"
            " so set it explicitly before deploying to a live chain."
        );
        return msg.sender;
    }

    function run() external returns (BazaarFactory factory, HelperConfig helperConfig) {
        return deploy(_resolveBugBountyRecipient());
    }

    function deploy(address bugBountyAddress) public returns (BazaarFactory factory, HelperConfig helperConfig) {
        _assertExpectedChain();
        _assertLinkedLibraries();
        // The factory rejects the zero address itself (Factory__ZeroAddress), but only after the
        // oracle, the pair implementation, the lens and the terminator have already been
        // broadcast. Checking before the first broadcast is what keeps a rejected run from
        // stranding four live contracts and a consumed nonce sequence.
        require(bugBountyAddress != address(0), "bugBountyAddress is the zero address");

        helperConfig = new HelperConfig();
        (address pythFeed, address usdcContract, address optimisticOracleV3, string memory networkName) =
            helperConfig.activeNetworkConfig();
        _assertExternalDependencies(pythFeed, usdcContract, optimisticOracleV3);

        console.log("----------------------------------------------------");
        console.log("Deploying Bazaar to:", networkName);
        console.log("  USDC:              ", usdcContract);
        console.log("  Pyth:              ", pythFeed);
        console.log("  OptimisticOracleV3:", optimisticOracleV3);
        console.log("  Bug bounty:        ", bugBountyAddress);
        console.log("----------------------------------------------------");

        vm.startBroadcast();

        // 1. Deploy contracts that don't depend on the factory
        BazaarOracle bazaarOracle = new BazaarOracle(pythFeed);
        console.log("BazaarOracle:            ", address(bazaarOracle));

        BazaarPair pairImplementation = new BazaarPair();
        console.log("BazaarPair implementation:", address(pairImplementation));

        // 2. Deploy the lens and the terminator against the CREATE-predicted factory address
        //    (each carries an immutable `factory`). Deploying them inside the factory constructor
        //    would push the initcode past the EIP-3860 limit. The factory constructor re-checks
        //    both wirings on-chain (Factory__WiringMismatch), so a wrong prediction cannot deploy
        //    a mis-wired system — it just reverts. +2: the lens and the terminator each consume a
        //    nonce before the factory's CREATE.
        (, address broadcaster,) = vm.readCallers();
        address predictedFactory = vm.computeCreateAddress(broadcaster, vm.getNonce(broadcaster) + 2);

        BazaarPairLens bazaarLens = new BazaarPairLens(predictedFactory);
        console.log("BazaarPairLens:          ", address(bazaarLens));

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
