// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

/// @notice Mock ArbSys precompile for Foundry tests.
///         Returns block.number so tests behave identically on non-Arbitrum chains.
contract MockArbSys {
    function arbBlockNumber() external view returns (uint256) {
        return block.number;
    }
}
