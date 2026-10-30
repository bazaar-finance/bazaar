// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

/// @title BazaarTradingAccount
/// @notice The smallest contract account that trades on Bazaar from one transaction carrying
///         several calls: fund the account, create orders, amend, cancel, claim, withdraw. As far
///         as every pair is concerned the account is the trader: collateral, positions, resting
///         orders and claimable fees belong to this address, and its owner directs it.
/// @dev An example to deploy for yourself, not part of the protocol: review it to your own
///      standard and keep the owner key as safe as the funds it controls. Any smart wallet that
///      batches calls (an ERC-4337 account, a Safe) does the same job; this is the least code
///      that does.
///
///      Calls run in order, and the first failure reverts the whole batch with that call's own
///      revert data, so a batch is atomic: every call took effect or none did. ETH sent with
///      `execute` funds the `value` of each call, which is how the Pyth update fee reaches the
///      call that carries a price update; a pair refunds what it does not use to this contract,
///      which `receive` accepts, and a later batch can send it on.
contract BazaarTradingAccount {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    address public immutable owner;

    error BazaarTradingAccount__NotOwner();
    error BazaarTradingAccount__ZeroOwner();

    constructor(address owner_) {
        if (owner_ == address(0)) revert BazaarTradingAccount__ZeroOwner();
        owner = owner_;
    }

    receive() external payable {}

    /// @notice Runs `calls` in order, each from this account with its `value`. Owner only.
    /// @param calls The calls to make; a failing one reverts the batch with its own revert data.
    /// @return results Each call's return data, in order.
    function execute(Call[] calldata calls) external payable returns (bytes[] memory results) {
        if (msg.sender != owner) revert BazaarTradingAccount__NotOwner();
        results = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!ok) {
                // Bubble the revert unchanged, so the batch fails with the pair's own error.
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            results[i] = ret;
        }
    }
}
