// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {CommonBase} from "forge-std/Base.sol";

/// @notice The externally-linked library set, shared by both deployment steps.
/// @dev    This list is the only place a library is named. Step 1 (`DeployLibraries`) deploys
///         each entry and records its link flag; step 2 (`DeployBazaar`) reads the record back and
///         checks that each recorded address holds the code the build links against. The artifact
///         id, the artifact path, the link placeholder, the link target, the flag and the record
///         path are all derived here, so a library cannot be deployed but left out of the flags,
///         or recorded but left unchecked. A new external library needs one edit here and a
///         matching bump of the array length.
abstract contract LinkedLibraries is CommonBase {
    function _libNames() internal pure returns (string[12] memory names) {
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
        names[10] = "VaultHealthLib";
        names[11] = "ClaimTextLib";
    }

    /// @dev Artifact id, as `vm.getCode` and `vm.getDeployedCode` take it.
    function _libArtifact(string memory name) internal pure returns (string memory) {
        return string.concat(name, ".sol:", name);
    }

    /// @dev The compiled artifact on disk, under foundry.toml's `out`. Both steps read it as a
    ///      file rather than through the `vm.getCode` family. Step 1 because `vm.getCode` refuses
    ///      an artifact that still carries a link reference: the libraries that call RiskParamsLib
    ///      carry one for it, and the flags that would resolve it are the output of step 1 itself.
    ///      Step 2 because the code it expects at a recorded address is defined by the record
    ///      alone (`_linkedRuntimeCode`), not by whatever library set this run's artifacts were
    ///      linked against, which is forge's own deployment on a dry run.
    function _libArtifactPath(string memory name) internal pure returns (string memory) {
        return string.concat("out/", name, ".sol/", name, ".json");
    }

    /// @dev `bytecode.object` (creation code) or `deployedBytecode.object` (runtime code) of a
    ///      library's raw artifact: a hex string with any link placeholders still in place.
    function _artifactObject(string memory name, bool deployed) internal view returns (string memory) {
        return vm.parseJsonString(
            vm.readFile(_libArtifactPath(name)), deployed ? ".deployedBytecode.object" : ".bytecode.object"
        );
    }

    /// @dev Link target, as forge's `--libraries` flag names it: `<source path>:<library>`.
    function _libLinkTarget(string memory name) internal pure returns (string memory) {
        return string.concat("src/libraries/", name, ".sol:", name);
    }

    /// @dev The placeholder solc leaves in unlinked bytecode where a library's address goes:
    ///      `__$`, the first 34 hex digits of the keccak256 of the fully qualified library name,
    ///      `$__` — 40 characters, the width of the address that replaces it.
    function _linkPlaceholder(string memory name) internal pure returns (string memory) {
        bytes32 h = keccak256(bytes(_libLinkTarget(name)));
        return string.concat("__$", _hex(abi.encodePacked(bytes17(h))), "$__");
    }

    /// @dev `object`, an artifact's creation or runtime code as a hex string, with the placeholder
    ///      of every library whose `linked` flag is set replaced by its address in `at`. Reports
    ///      whether every placeholder was replaced, so a caller can hold a library back until
    ///      what it links against has an address.
    function _linkCode(string memory object, string[12] memory names, address[12] memory at, bool[12] memory linked)
        internal
        pure
        returns (string memory, bool resolved)
    {
        for (uint256 i; i < names.length; ++i) {
            if (!linked[i]) continue;
            object = vm.replace(object, _linkPlaceholder(names[i]), _hex(abi.encodePacked(at[i])));
        }
        resolved = vm.indexOf(object, "__$") == type(uint256).max;
        return (object, resolved);
    }

    /// @dev The runtime code `name` holds on chain when deployed from this build beside the set
    ///      recorded at `at`: its artifact's runtime code with every link placeholder resolved to
    ///      the address recorded for the library it names. A record is thereby checked against
    ///      itself: a dependent recorded beside a RiskParamsLib other than the one its link slots
    ///      hold does not match. An artifact this build already linked carries no placeholder and
    ///      is returned as it is, so its slots hold the addresses the run was linked with, which
    ///      the code at the recorded address must then agree with. A placeholder naming a library
    ///      outside `names` is refused: nothing in the set could hold its code.
    function _linkedRuntimeCode(string memory name, string[12] memory names, address[12] memory at)
        internal
        view
        returns (bytes memory)
    {
        bool[12] memory linked;
        for (uint256 i; i < names.length; ++i) {
            linked[i] = true;
        }
        (string memory object, bool resolved) = _linkCode(_artifactObject(name, true), names, at, linked);
        require(resolved, string.concat(name, " links a library outside _libNames()"));
        return vm.parseBytes(object);
    }

    /// @dev Lower-case hex digits of `b`, without the `0x` prefix.
    function _hex(bytes memory b) internal pure returns (string memory) {
        bytes memory s = bytes(vm.toString(b));
        bytes memory out = new bytes(s.length - 2);
        for (uint256 i = 2; i < s.length; ++i) {
            out[i - 2] = s[i];
        }
        return string(out);
    }

    /// @dev One link flag, as forge takes it on the command line and as the record stores it.
    function _libLinkFlag(string memory name, address addr) internal pure returns (string memory) {
        return string.concat("--libraries ", _libLinkTarget(name), ":", vm.toString(addr));
    }

    /// @dev The per-chain record directory. Keyed by chain id because a library address is only
    ///      meaningful on the chain it was deployed to; one shared list would let a rehearsal
    ///      network's addresses be linked into a production build.
    function _libArgsDir(uint256 chainId) internal pure returns (string memory) {
        return string.concat("deployments/", vm.toString(chainId));
    }

    /// @dev Where step 1 writes a chain's link flags and step 2 reads them back.
    function _libArgsPath(uint256 chainId) internal pure returns (string memory) {
        return string.concat(_libArgsDir(chainId), "/libraries.args");
    }

    /// @dev Truncates `code` in place to drop its CBOR metadata trailer and returns it. The
    ///      trailer is self-describing: the last two bytes give the CBOR map's length, and the map
    ///      opens with a major-type-5 header (0xa1..0xa3 for the one to three keys solc writes).
    ///      Code without a recognisable trailer is refused rather than compared whole, so a build
    ///      that disabled metadata cannot have a mismatch hidden in whatever those bytes decode to.
    function _stripMetadata(bytes memory code) internal pure returns (bytes memory) {
        uint256 n = code.length;
        require(n >= 2, "runtime code has no CBOR metadata trailer");
        uint256 cborLen = (uint256(uint8(code[n - 2])) << 8) | uint256(uint8(code[n - 1]));
        require(cborLen + 2 < n, "runtime code has no CBOR metadata trailer");
        uint8 header = uint8(code[n - 2 - cborLen]);
        require(header >= 0xa1 && header <= 0xa3, "runtime code has no CBOR metadata trailer");
        assembly ("memory-safe") {
            mstore(code, sub(sub(n, 2), cborLen))
        }
        return code;
    }

    /// @dev Zeroes, in place, every 20-byte window of `code` that equals `self`, and returns it.
    ///      Only the embedded self-address can match: any other window equals a fresh address with
    ///      probability 2^-160.
    function _maskSelfAddress(bytes memory code, address self) internal pure returns (bytes memory) {
        bytes20 needle = bytes20(self);
        uint256 n = code.length;
        for (uint256 i; i + 20 <= n; ++i) {
            uint256 j;
            while (j < 20 && code[i + j] == needle[j]) ++j;
            if (j == 20) {
                for (j = 0; j < 20; ++j) {
                    code[i + j] = 0;
                }
                i += 19;
            }
        }
        return code;
    }
}
