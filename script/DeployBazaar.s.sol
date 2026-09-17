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
    ///      as a bricked protocol later. Mock networks accept any identifier (mock whitelist
    ///      defaults to supported).
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
