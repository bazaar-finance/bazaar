// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice An ERC20 that returns `false` on transfer / transferFrom instead of reverting,
///         simulating non-standard tokens that the unsafe `(bool ok,) = address(token).call(...)`
///         pattern would treat as success. Used to regress the Phase 1 SafeERC20 migration.
contract MockUSDCSilentFail is ERC20 {
    bool public failTransfer;
    bool public failTransferFrom;

    constructor() ERC20("Silent Fail USDC", "sfUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFailTransfer(bool v) external {
        failTransfer = v;
    }

    function setFailTransferFrom(bool v) external {
        failTransferFrom = v;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfer) return false; // silently fail
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransferFrom) return false;
        return super.transferFrom(from, to, amount);
    }
}
