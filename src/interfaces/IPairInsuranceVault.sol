// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

/**
 * @title IInsuranceVault
 * @notice Interface for the InsuranceVault contract
 */
interface IInsuranceVault {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getTotalBalance() external view returns (uint256);
    function balance() external view returns (uint256);
    function pair() external view returns (address);
}
