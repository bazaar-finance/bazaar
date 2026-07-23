// contracts/MockUSDC.sol
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract MockUSDC is ERC20, ERC20Permit {
    constructor() ERC20("Mock USD Coin", "USDC") ERC20Permit("Mock USD Coin") {}

    function decimals() public pure override returns (uint8) {
        return 6; // USDC has 6 decimals, not 18
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
