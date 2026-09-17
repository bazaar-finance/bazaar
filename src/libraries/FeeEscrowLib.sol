// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {BazaarTypes} from "./BazaarTypes.sol";

/// @title FeeEscrowLib
/// @notice The single write path into a pair's fee escrow. Every USDC the pair owes a third
///         party — integrator fees, the bug-bounty tax, keeper tips and rewards (trigger
///         execution, vault unload, liquidation, ADL, price refresh), the UMA proposer reward
///         and meta-tx relayer fees — is accrued here and pulled later through
///         BazaarPair.claimFees.
/// @dev Internal (inlined) so the crediting libraries and the pair share one body. Accruing
///      instead of transferring keeps token calls out of every entry point that pays a third
///      party: no transfer can fail mid-batch, a recipient USDC refuses simply never claims,
///      and nothing a receiver outside the protocol's trust boundary does can revert or
///      re-enter the payer. The debit that funds a credit — the insurance fund, the deposits
///      ledger, or USDC the caller just pulled in — is the caller's responsibility; the escrow
///      only records the liability, and `total` is what every books-vs-cash figure reserves
///      for it.
library FeeEscrowLib {
    /// @notice Accrue `amount` (BAZAAR precision) to `recipient`'s claimable balance.
    /// @dev Callers guard against a zero amount; an unconditional credit would only burn gas on
    ///      an empty event.
    function credit(BazaarTypes.FeeEscrow storage escrow, bytes32 pairId, address recipient, uint256 amount) internal {
        escrow.claimable[recipient] += amount;
        unchecked {
            // total is the sum of all claimable balances, each of which just passed a checked add.
            escrow.total += amount;
        }
        emit BazaarTypes.FeeAccrued(pairId, recipient, amount);
    }
}
