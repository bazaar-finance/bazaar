// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

/// @notice Step 1: Deploy all external libraries used by BazaarPair.
///         After running this script, paste the printed libraries array into
///         foundry.toml [profile.default] then run DeployBazaar.
contract DeployLibraries is Script {
    function _deployLib(string memory artifact) internal returns (address addr) {
        bytes memory bytecode = vm.getCode(artifact);
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(addr != address(0), string.concat("Failed to deploy ", artifact));
    }

    function run() external {
        vm.startBroadcast();

        address insuranceVaultLib = _deployLib("InsuranceVaultLib.sol:InsuranceVaultLib");
        address liquidationLib = _deployLib("LiquidationLib.sol:LiquidationLib");
        address orderManagementLib = _deployLib("OrderManagementLib.sol:OrderManagementLib");
        address adlLib = _deployLib("AdlLib.sol:AdlLib");
        address matchingEngineLib = _deployLib("MatchingEngineLib.sol:MatchingEngineLib");
        address collateralLib = _deployLib("CollateralLib.sol:CollateralLib");
        address riskParamsLib = _deployLib("RiskParamsLib.sol:RiskParamsLib");
        address fundingLib = _deployLib("FundingLib.sol:FundingLib");

        vm.stopBroadcast();

        console.log("----------------------------------------------------");
        console.log("External libraries deployed. Add to foundry.toml:");
        console.log("----------------------------------------------------");
        console.log("libraries = [");
        console.log('    "src/libraries/InsuranceVaultLib.sol:InsuranceVaultLib:%s",', insuranceVaultLib);
        console.log('    "src/libraries/LiquidationLib.sol:LiquidationLib:%s",', liquidationLib);
        console.log('    "src/libraries/OrderManagementLib.sol:OrderManagementLib:%s",', orderManagementLib);
        console.log('    "src/libraries/AdlLib.sol:AdlLib:%s",', adlLib);
        console.log('    "src/libraries/MatchingEngineLib.sol:MatchingEngineLib:%s",', matchingEngineLib);
        console.log('    "src/libraries/CollateralLib.sol:CollateralLib:%s",', collateralLib);
        console.log('    "src/libraries/RiskParamsLib.sol:RiskParamsLib:%s",', riskParamsLib);
        console.log('    "src/libraries/FundingLib.sol:FundingLib:%s",', fundingLib);
        console.log("]");
        console.log("----------------------------------------------------");
    }
}
