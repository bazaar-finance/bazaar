// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.20;

/// @notice Minimal subset of the Arbitrum ArbSys precompile at address 0x64.
///         arbBlockNumber() returns the Arbitrum L2 block number
interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}
