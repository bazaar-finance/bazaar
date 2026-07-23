# Gasless Transactions

Every user-facing action on a pair — deposits, withdrawals, order creation and cancellation, insurance deposits/withdrawals — can be executed by a **relayer** carrying the user's EIP-712 signature. Combined with ERC-2612 permit for USDC approvals, a trader needs no ETH at all.

## How it works

Each function takes a trailing `(nonce, deadline, relayerFee, signature)` tuple:

- Empty signature → normal transaction, `msg.sender` is the actor, fee ignored.
- Non-empty → the contract recovers the signer over the typed payload and acts as *them*; whoever submitted the transaction collects `relayerFee` in USDC.

| Rule | Value |
|---|---|
| Domain | name `"BazaarPair"`, version `"1"`, chainId, verifying contract (re-derived if chainId changes — fork protection) |
| Nonces | strictly sequential per user |
| Deadline | must not be passed, and at most **30 s** in the future — a signature cannot be warehoused |
| Relayer fee | ≤ **$1** per action — deducted from the payout on withdrawals, pulled from the user's wallet alongside deposits (and for insurance-withdrawal requests), or charged to bucket collateral for order create/cancel |
| Price staleness | relayed calls use the strict 2 s tier, not the 10 s user tier — relayers are bots |

Typed structs exist for `depositCollateral`, `withdrawCollateral`, `createOrder`, `cancelOrders`, `depositToInsurance`, `requestInsuranceWithdrawal`, `executeInsuranceWithdrawal`. `BazaarPairLens.getEip712Constants()` and `getTypehashes()` expose everything an integrator needs to build signatures.

## Permit deposits

Deposit functions accept an optional ERC-2612 `permitData`, executed best-effort before the pull — approval and deposit in one signature. A failed permit emits `PermitExecutionFailed` and falls through to the normal allowance path (so a griefed permit can't block a deposit that would succeed anyway).
