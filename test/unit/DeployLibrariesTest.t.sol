// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {DeployLibraries} from "../../script/DeployLibraries.s.sol";
import {LinkedLibraries} from "../../script/LinkedLibraries.sol";

/// @dev Exposes step 1's deployment and the link resolution it is built on.
contract DeployLibrariesHarness is DeployLibraries {
    function deployAll() external returns (address[12] memory) {
        return _deployAll();
    }

    function linkCode(string memory object, string[12] memory names, address[12] memory at, bool[12] memory linked)
        external
        pure
        returns (string memory, bool)
    {
        return _linkCode(object, names, at, linked);
    }

    function artifactObject(string memory name, bool deployed) external view returns (string memory) {
        return _artifactObject(name, deployed);
    }

    function stripMetadata(bytes memory code) external pure returns (bytes memory) {
        return _stripMetadata(code);
    }

    function maskSelfAddress(bytes memory code, address self) external pure returns (bytes memory) {
        return _maskSelfAddress(code, self);
    }
}

/// @notice Step 1 deploys from the raw artifacts, which is all a `forge script` run has: the
///         libraries that call RiskParamsLib carry its link placeholder, which forge resolves only
///         from `--libraries` flags, the very output step 1 exists to produce. The script links
///         them itself, and these tests pin that every deployed library holds its artifact's
///         runtime code with the RiskParamsLib deployed in the same run in every link slot.
///
///         The test runner links every artifact before a test sees it, so `vm.getCode` succeeds
///         here where the script runner refuses it. The files on disk are the unlinked ones either
///         way, and they are what the script and these tests read.
contract DeployLibrariesTest is Test, LinkedLibraries {
    DeployLibrariesHarness internal dep;
    string[12] internal names;
    address[12] internal addrs;

    function setUp() public {
        dep = new DeployLibrariesHarness();
        names = _libNames();
        addrs = dep.deployAll();
    }

    function _index(string memory name) internal view returns (uint256 i) {
        while (i < names.length && keccak256(bytes(names[i])) != keccak256(bytes(name))) ++i;
        require(i < names.length, "not a linked library");
    }

    function _hasPlaceholder(string memory object) internal pure returns (bool) {
        return vm.indexOf(object, "__$") != type(uint256).max;
    }

    /// @dev The 40-character placeholder at the first `__$` of `object`, read off the artifact
    ///      rather than derived, so the derivation the script uses is checked against solc's.
    function _firstPlaceholder(string memory object) internal pure returns (string memory) {
        uint256 at = vm.indexOf(object, "__$");
        bytes memory s = bytes(object);
        bytes memory out = new bytes(40);
        for (uint256 i; i < 40; ++i) {
            out[i] = s[at + i];
        }
        return string(out);
    }

    /// @dev Lower-case hex digits of `a`, as the script writes them into the code.
    function _hexAddress(address a) internal pure returns (string memory) {
        bytes memory s = bytes(vm.toLowercase(vm.toString(a)));
        bytes memory out = new bytes(40);
        for (uint256 i; i < 40; ++i) {
            out[i] = s[i + 2];
        }
        return string(out);
    }

    /// @notice The raw artifacts are unlinked: the five libraries that call RiskParamsLib carry a
    ///         placeholder, in their creation and their runtime code alike, and the other seven
    ///         carry none.
    function test_artifacts_fiveCarryRiskParamsLibPlaceholder() public view {
        uint256 unlinked;
        for (uint256 i; i < names.length; ++i) {
            bool creation = _hasPlaceholder(dep.artifactObject(names[i], false));
            bool runtime = _hasPlaceholder(dep.artifactObject(names[i], true));
            assertEq(creation, runtime, string.concat(names[i], ": creation and runtime code agree"));
            if (creation) ++unlinked;
        }
        assertEq(unlinked, 5, "five libraries link RiskParamsLib");
        assertFalse(_hasPlaceholder(dep.artifactObject("RiskParamsLib", false)), "RiskParamsLib links nothing");
    }

    /// @notice Every deployed library holds its artifact's runtime code with this run's
    ///         RiskParamsLib address in every link slot: the comparison step 2 applies to the
    ///         record, with the placeholder located in the raw artifact rather than derived.
    function test_deployAll_linksEveryPlaceholderToThisRunsRiskParamsLib() public view {
        address risk = addrs[_index("RiskParamsLib")];
        for (uint256 i; i < names.length; ++i) {
            string memory object = dep.artifactObject(names[i], true);
            if (_hasPlaceholder(object)) {
                object = vm.replace(object, _firstPlaceholder(object), _hexAddress(risk));
                assertFalse(_hasPlaceholder(object), string.concat(names[i], ": one placeholder links it all"));
            }
            bytes memory expected = dep.stripMetadata(vm.parseBytes(object));
            bytes memory actual = dep.maskSelfAddress(dep.stripMetadata(addrs[i].code), addrs[i]);
            assertEq(keccak256(actual), keccak256(expected), string.concat(names[i], ": the linked artifact"));
        }
    }

    /// @notice A dependent library is held back until RiskParamsLib has an address: with nothing
    ///         deployed its placeholder stays unresolved, and with RiskParamsLib deployed it
    ///         resolves to that address. Code with no placeholder passes through unchanged.
    function test_linkCode_resolvesOnlyAgainstDeployedLibraries() public {
        string memory object = dep.artifactObject("AdlLib", false);
        address[12] memory at;
        bool[12] memory linked;
        (, bool resolved) = dep.linkCode(object, names, at, linked);
        assertFalse(resolved, "nothing deployed: unresolved");

        uint256 r = _index("RiskParamsLib");
        at[r] = makeAddr("risk");
        linked[r] = true;
        (string memory out, bool ok) = dep.linkCode(object, names, at, linked);
        assertTrue(ok, "RiskParamsLib deployed: resolved");
        assertEq(out, vm.replace(object, _firstPlaceholder(object), _hexAddress(at[r])), "the slot holds the address");

        string memory plain = dep.artifactObject("RiskParamsLib", false);
        (string memory same, bool stillOk) = dep.linkCode(plain, names, at, linked);
        assertTrue(stillOk, "no placeholder: resolved");
        assertEq(same, plain, "returned as is");
    }
}
