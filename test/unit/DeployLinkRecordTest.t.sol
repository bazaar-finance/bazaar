// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {DeployLibraries} from "../../script/DeployLibraries.s.sol";
import {LinkedLibraries} from "../../script/LinkedLibraries.sol";

/// @dev Drives the record check with a string instead of the on-disk file, and exposes the two
///      normalisations so each can be shown to be load-bearing on its own.
contract DeployBazaarHarness is DeployBazaar {
    function verifyLinkRecord(string memory record) external view {
        _verifyLinkRecord(record);
    }

    function stripMetadata(bytes memory code) external pure returns (bytes memory) {
        return _stripMetadata(code);
    }

    function maskSelfAddress(bytes memory code, address self) external pure returns (bytes memory) {
        return _maskSelfAddress(code, self);
    }
}

/// @dev Step 1's deployment, exposed so the fixtures hold what a real step 1 leaves on chain.
contract StepOneHarness is DeployLibraries {
    function deployAll() external returns (address[12] memory) {
        return _deployAll();
    }
}

/// @notice Step 2's check of step 1's record: every linked library must be recorded exactly once,
///         and each recorded address must hold the runtime code of its artifact linked against
///         the recorded set. Here the libraries are deployed as step 1 deploys them, from the raw
///         artifacts with the RiskParamsLib of the same deployment in every link slot, so the
///         on-chain code carries exactly what a real deployment's does: the library's own address
///         embedded for call protection, the metadata trailer, and the link slots resolved.
///
///         The file-reading entry point is gated on `EXPECTED_CHAIN_ID`, which cannot be pinned
///         from a test without leaking into every other test in the process, so the check is
///         driven through `_verifyLinkRecord` directly. The one case that touches the disk runs
///         the real step 1 and reads its file back, so the record format is tested against its
///         producer rather than against a copy of it.
contract DeployLinkRecordTest is Test, LinkedLibraries {
    DeployBazaarHarness internal dep;
    string[12] internal names;
    address[12] internal addrs;

    function setUp() public {
        dep = new DeployBazaarHarness();
        names = _libNames();
        addrs = new StepOneHarness().deployAll();
    }

    /// @dev The record as step 1 writes it, with `names[i]` recorded at `at[i]`.
    function _record(address[12] memory at) internal view returns (string memory r) {
        for (uint256 i; i < names.length; ++i) {
            r = string.concat(r, i == 0 ? "" : " ", _libLinkFlag(names[i], at[i]));
        }
    }

    function _noCodeReason(uint256 i, address at) internal view returns (bytes memory) {
        return bytes(
            string.concat(
                names[i],
                " at ",
                vm.toString(at),
                " holds no code on chain ",
                vm.toString(block.chainid),
                " -- re-run step 1"
            )
        );
    }

    function _wrongCodeReason(uint256 i, address at) internal view returns (bytes memory) {
        return bytes(
            string.concat(
                names[i], " at ", vm.toString(at), " does not hold the code this build links against -- re-run step 1"
            )
        );
    }

    // ------------------------------------------------------------------------------------------
    // Acceptance
    // ------------------------------------------------------------------------------------------

    /// @notice Step 1's own output passes step 2's check: the file it writes for this chain,
    ///         read back verbatim, names every library at an address holding its code.
    function test_record_acceptsStepOneOutput() public {
        new DeployLibraries().run();
        string memory path = _libArgsPath(block.chainid);
        string memory record = vm.readFile(path);
        vm.removeDir(_libArgsDir(block.chainid), true);

        dep.verifyLinkRecord(record);
        // An editor's trailing newline is not a malformed flag.
        dep.verifyLinkRecord(string.concat(record, "\n"));
    }

    /// @notice The libraries step 1 deployed here pass, which is what the failure cases below
    ///         mutate away from.
    function test_record_acceptsStepOneDeployments() public view {
        dep.verifyLinkRecord(_record(addrs));
    }

    // ------------------------------------------------------------------------------------------
    // The two normalisations, each shown to be necessary
    // ------------------------------------------------------------------------------------------

    /// @notice Step 1 compiles with no link flags and step 2 with all of them, and
    ///         `settings.libraries` is part of every contract's metadata, so the on-chain trailer
    ///         never matches step 2's artifact. A trailer whose every payload byte differs is
    ///         accepted (the CBOR header and length bytes stay, as they do in any solc build);
    ///         one byte of the code body is not.
    function test_record_ignoresTheMetadataTrailerOnly() public {
        bytes memory code = addrs[0].code;
        uint256 bodyLen = dep.stripMetadata(addrs[0].code).length;
        assertLt(bodyLen, code.length, "the artifact carries a trailer");

        for (uint256 i = bodyLen + 1; i < code.length - 2; ++i) {
            code[i] = ~code[i];
        }
        vm.etch(addrs[0], code);
        dep.verifyLinkRecord(_record(addrs));

        code = addrs[0].code;
        code[bodyLen - 1] = ~code[bodyLen - 1];
        vm.etch(addrs[0], code);
        vm.expectRevert(_wrongCodeReason(0, addrs[0]));
        dep.verifyLinkRecord(_record(addrs));
    }

    /// @notice The deployed library embeds its own address where the artifact holds zeros; that is
    ///         the only difference between the two code bodies once the artifact's link slots are
    ///         resolved to the recorded set, and masking it is what makes them compare equal. The
    ///         embedding is solc's call protection, which only a library with a state-changing
    ///         entry point carries: CollateralLib has them, so its body differs until masked,
    ///         while a library whose entry points are all view already matches and the mask finds
    ///         nothing to zero.
    function test_record_selfAddressIsTheOnlyBodyDifference() public view {
        for (uint256 i; i < names.length; ++i) {
            bytes memory artifact = dep.stripMetadata(_linkedRuntimeCode(names[i], names, addrs));
            bytes memory onChain = dep.stripMetadata(addrs[i].code);
            assertEq(onChain.length, artifact.length, names[i]);
            if (keccak256(bytes(names[i])) == keccak256("CollateralLib")) {
                assertNotEq(keccak256(onChain), keccak256(artifact), "CollateralLib: unmasked");
            }
            assertEq(
                keccak256(dep.maskSelfAddress(onChain, addrs[i])),
                keccak256(artifact),
                string.concat(names[i], ": masked")
            );
        }
    }

    /// @notice A record assembled from two library deployments is refused: the dependents delegate
    ///         into the RiskParamsLib deployed beside them, and the record names another one, so
    ///         the first dependent in the list fails the code check although every address holds
    ///         the code of the library recorded there.
    function test_record_rejectsDependentsLinkedToAnotherRiskParamsLib() public {
        address[12] memory other = new StepOneHarness().deployAll();
        uint256 r;
        while (keccak256(bytes(names[r])) != keccak256("RiskParamsLib")) ++r;
        address[12] memory at = addrs;
        at[r] = other[r];

        vm.expectRevert(_wrongCodeReason(0, at[0]));
        dep.verifyLinkRecord(_record(at));
    }

    /// @notice The right code at the wrong address is refused: its embedded self-address is not
    ///         the recorded one, and its call protection would reject every DELEGATECALL.
    function test_record_rejectsTheRightCodeAtAnotherAddress() public {
        address copy = makeAddr("copy");
        vm.etch(copy, addrs[0].code);
        address[12] memory at = addrs;
        at[0] = copy;

        vm.expectRevert(_wrongCodeReason(0, copy));
        dep.verifyLinkRecord(_record(at));
    }

    // ------------------------------------------------------------------------------------------
    // Record defects
    // ------------------------------------------------------------------------------------------

    /// @notice An address with no code — an interrupted step 1, or a record from another chain.
    function test_record_rejectsAddressWithoutCode() public {
        address empty = makeAddr("empty");
        address[12] memory at = addrs;
        at[3] = empty;

        vm.expectRevert(_noCodeReason(3, empty));
        dep.verifyLinkRecord(_record(at));
    }

    /// @notice A record whose addresses hold code, but not the code recorded under that name.
    function test_record_rejectsCodeOfAnotherLibrary() public {
        address[12] memory at = addrs;
        (at[0], at[1]) = (at[1], at[0]);

        vm.expectRevert(_wrongCodeReason(0, at[0]));
        dep.verifyLinkRecord(_record(at));
    }

    /// @notice A record short of one library: forge would deploy the missing one itself, unrecorded.
    function test_record_rejectsMissingLibrary() public {
        string memory record;
        for (uint256 i; i < names.length - 1; ++i) {
            record = string.concat(record, i == 0 ? "" : " ", _libLinkFlag(names[i], addrs[i]));
        }

        vm.expectRevert(bytes("libraries.args: expected exactly one --libraries flag per linked library"));
        dep.verifyLinkRecord(record);
    }

    /// @notice A duplicate entry keeps the flag count right but displaces another library, which
    ///         is reported as the missing one.
    function test_record_rejectsDuplicateEntry() public {
        string memory record;
        for (uint256 i; i < names.length; ++i) {
            uint256 k = i == 1 ? 0 : i;
            record = string.concat(record, i == 0 ? "" : " ", _libLinkFlag(names[k], addrs[k]));
        }

        vm.expectRevert(bytes(string.concat("libraries.args: no entry for ", names[1], " -- re-run step 1")));
        dep.verifyLinkRecord(record);
    }

    /// @notice A flag that is not forge's `--libraries`, and a link target outside `src/libraries`.
    function test_record_rejectsMalformedFlags() public {
        string memory good = _record(addrs);
        string memory broken =
            vm.replace(good, "--libraries src/libraries/AdlLib.sol", "--library src/libraries/AdlLib.sol");
        vm.expectRevert(bytes("libraries.args: malformed flag: --library"));
        dep.verifyLinkRecord(broken);

        broken = vm.replace(good, "src/libraries/AdlLib.sol:AdlLib", "src/AdlLib.sol:AdlLib");
        vm.expectRevert(
            bytes(
                string.concat(
                    "libraries.args: link target is not a src/libraries library: src/AdlLib.sol:AdlLib:",
                    vm.toString(addrs[3])
                )
            )
        );
        dep.verifyLinkRecord(broken);
    }
}
