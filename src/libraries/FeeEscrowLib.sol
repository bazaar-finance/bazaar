// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {BazaarTypes} from "./BazaarTypes.sol";

/// @title FeeEscrowLib
/// @notice The single write path into a pair's fee escrow. Every USDC the pair owes a third
///         party — integrator fees, the bug-bounty tax, keeper bounties and rewards (trigger
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
            // total is the sum of all claimable balances and held bounties, each of which just
            // passed a checked add.
            escrow.total += amount;
        }
        emit BazaarTypes.FeeAccrued(pairId, recipient, amount);
    }

    /// @notice Record a trigger order's keeper bounty, held against the order until it is
    ///         assigned. The caller has just pulled the same amount of USDC into the pair.
    /// @dev Written once per order, at creation, so the slot is empty on entry.
    function escrowBounty(BazaarTypes.FeeEscrow storage escrow, bytes32 pairId, uint256 orderId, uint256 amount)
        internal
    {
        escrow.bounty[orderId] = amount;
        escrow.total += amount;
        emit BazaarTypes.TriggerBountyEscrowed(pairId, orderId, amount);
    }

    /// @notice Move `amount` of `orderId`'s held bounty into `recipient`'s claimable balance.
    /// @dev `total` is unchanged: the cash was reserved when the bounty was escrowed, and
    ///      assignment only settles who may claim it. Callers bound `amount` by the held
    ///      bounty; the checked subtraction turns a regression there into a revert rather than a
    ///      phantom credit.
    function assignBounty(
        BazaarTypes.FeeEscrow storage escrow,
        bytes32 pairId,
        uint256 orderId,
        address recipient,
        uint256 amount
    ) internal {
        escrow.bounty[orderId] -= amount;
        escrow.claimable[recipient] += amount;
        emit BazaarTypes.FeeAccrued(pairId, recipient, amount);
        emit BazaarTypes.TriggerBountyReleased(pairId, orderId, recipient, amount);
    }

    /// @notice Return whatever bounty `orderId` still holds to `owner`'s claimable balance.
    /// @dev The exit for an order that ended outside a walk's own settlement: an owner cancel,
    ///      expiry, or a terminal write that had no escrow in hand (the TP/SL fence, a
    ///      liquidation or deleverage reset). A no-op when nothing is held, so every such path
    ///      may call it unconditionally.
    function refundBounty(BazaarTypes.FeeEscrow storage escrow, bytes32 pairId, uint256 orderId, address owner)
        internal
    {
        uint256 held = escrow.bounty[orderId];
        if (held != 0) assignBounty(escrow, pairId, orderId, owner, held);
    }
}
