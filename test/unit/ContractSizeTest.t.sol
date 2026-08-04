// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

/// @notice Deployability gate: every contract and external library we ship to a live chain
///         must fit the EIP-170 runtime-size limit, or deployment reverts on every mainnet.
///         Forge's test EVM does NOT enforce EIP-170, so without this assertion an oversized
///         contract sails through the whole suite and only fails at real deployment (or as a
///         disguised Factory__OracleProbeFailed in factory-path tests).
///         Test-only harnesses are deliberately excluded — they never ship. This is the
///         precise replacement for gating CI on `forge build --sizes`, whose failure banner
///         also covers test contracts and whose exit code varies across forge versions.
contract ContractSizeTest is Test {
    uint256 internal constant EIP170_RUNTIME_LIMIT = 24_576;

    /// @dev Artifact ids for everything DeployBazaar/DeployLibraries put on chain.
    ///      New deployable contract or external library => add it here.
    function _deployableArtifacts() internal pure returns (string[16] memory a) {
        a = [
            // Core contracts
            "BazaarFactory.sol:BazaarFactory",
            "BazaarPair.sol:BazaarPair",
            "BazaarPairTerminator.sol:BazaarPairTerminator",
            "BazaarPairLens.sol:BazaarPairLens",
            "BazaarOracle.sol:BazaarOracle",
            "BazaarSequencer.sol:BazaarSequencer",
            // External (separately deployed, delegatecalled) libraries
            "AdlLib.sol:AdlLib",
            "CollateralLib.sol:CollateralLib",
            "FundingLib.sol:FundingLib",
            "InsuranceVaultLib.sol:InsuranceVaultLib",
            "LiquidationLib.sol:LiquidationLib",
            "MatchingEngineLib.sol:MatchingEngineLib",
            "MetaTxLib.sol:MetaTxLib",
            "OrderManagementLib.sol:OrderManagementLib",
            "RiskParamsLib.sol:RiskParamsLib",
            "TerminationLib.sol:TerminationLib"
        ];
    }

    function test_deployableContractsFitEip170() public view {
        string[16] memory artifacts = _deployableArtifacts();
        for (uint256 i = 0; i < artifacts.length; ++i) {
            uint256 size = vm.getDeployedCode(artifacts[i]).length;
            assertLe(size, EIP170_RUNTIME_LIMIT, artifacts[i]);
        }
    }
}
