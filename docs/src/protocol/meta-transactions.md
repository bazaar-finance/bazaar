# Gasless Transactions

Every user-facing action on a pair — deposits, withdrawals, order creation and cancellation, insurance deposits/withdrawals — can be executed by a **relayer** carrying the user's EIP-712 signature. Combined with ERC-2612 permit for USDC approvals, a trader needs no ETH at all.

## How it works

Each function takes a `(nonce, deadline, relayerFee, signature)` tuple, and the functions that pull USDC from the wallet — the deposits, `requestInsuranceWithdrawal`, `createOrder` and `cancelOrders` — take a trailing `permitData` after it:

- Empty signature → normal transaction, `msg.sender` is the actor, fee ignored.
- Non-empty → the contract recovers the signer over the typed payload and acts as *them*; whoever submitted the transaction is credited `relayerFee` in USDC on their claimable balance, withdrawn with `claimFees()`.

| Rule | Value |
|---|---|
| Domain | name `"BazaarPair"`, version `"1"`, chainId, verifying contract (re-derived if chainId changes — fork protection) |
| Nonces | strictly sequential per user |
| Deadline | must not be passed, and at most **10 s** in the future (`MAX_DEADLINE_WINDOW`) — a signature cannot be warehoused |
| Relayer fee | ≤ **$1** per action — netted from the payout on withdrawals, pulled from the user's wallet alongside deposits, and pulled from the wallet on its own for order create/cancel and insurance-withdrawal requests. In every case the fee stays in the pair as the relayer's claimable balance, accrued per call and withdrawn with `claimFees()` in any pair state. Never charged to bucket collateral: margin backing a position leaves only through `withdrawCollateral` and its gates |
| Price staleness | the same 2 s bound as every other path — but `priceUpdate` sits outside the signed payload, so the relayer attaches a fresh price at submission and an earlier signature still lands on it |

Typed structs exist for `depositCollateral`, `withdrawCollateral`, `createOrder`, `cancelOrders`, `depositToInsurance`, `requestInsuranceWithdrawal`, `executeInsuranceWithdrawal`. `BazaarPairLens.getEip712Constants()` and `getTypehashes()` expose everything an integrator needs to build signatures.

## Permit

Every function that pulls USDC from the wallet accepts an optional ERC-2612 `permitData`, executed best-effort before the pull — approval and action in one signature. For the deposits the permit covers the deposit plus fee; for `createOrder`, `cancelOrders` and `requestInsuranceWithdrawal` it covers the relayer fee alone, so a trader who onboarded through a permit and holds no ETH can still trade and cancel gaslessly. A failed permit emits `PermitExecutionFailed` and falls through to the normal allowance path (so a griefed permit can't block a call that would succeed anyway).
