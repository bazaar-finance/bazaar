# Fees

All trading fees are charged per fill, on notional, deducted from each side's collateral. Rates are in *extended basis points* (EBP, 1/100 bp).

| Stream | Maker | Taker |
|---|---|---|
| Insurance | 0.5 bp | dynamic — steers the fund to target; see below |
| Integrator | 0.25 bp | 0.25 bp |

- **Dynamic taker insurance fee**: the base rate scales with the fund's [target ratio](insurance.md) — **0.5 bp** at the 2% minimum target, linear to **2 bp** at the 10% maximum. Below target it multiplies up sharply — base × (1 + 49 × shortfall²), hard-capped at **45 bp**. The base rate is a floor: at or above target the fee stays there and never discounts, however overfull the fund is. Risk-reducing size pays the base rate, so closing is never more expensive than opening. Exact curve: `RiskParamsLib.getInsuranceFeeRates`.
- **Integrator fee**: each order carries an optional `integrator` address (frontend/aggregator) that earns its cut on every fill of that order. Referral revenue is protocol-native — see the [integrator guide](../guide/integrators.md).
- **Bug-bounty tax**: **1% of every fee stream** (insurance, integrator) is skimmed into the claimable balance of a bug-bounty address fixed at factory deployment — a white-hat budget that accrues automatically from the first fill.

## Non-trading rewards

| Action | Reward | Funded from |
|---|---|---|
| Liquidation (per position) | max($0.10, 2 bp of notional) | insurance fund (free capital) |
| ADL execution | 0.1% of averted bad debt | insurance fund (free capital) |
| Trigger execution (per fired stop) | $0.25 (`TRIGGER_TIP`) | the stop owner's collateral, like a trading fee |
| Vault unload | 2 bp of unloaded notional; a $0.25 floor when ≥ $1,250 unloads or the inventory clears | insurance fund (free capital) |
| Price refresh | $0.25 (`REFRESH_BOUNTY`) | insurance fund (free capital) |
| Terminal settlement (per position settled for someone else) | $0.10 (`TERMINAL_SETTLEMENT_TIP`) | before finalize: the settled position's remaining collateral, insurance topping up; after finalize: the insurers' residual, bankrupt stragglers only |
| UMA termination proposer | 0.1% of the fund, capped $100, once per pair | insurance fund |
| Meta-transaction relay (per action) | the signed `relayerFee`, ≤ $1 | the signer's wallet or payout |

Rewards funded from the insurance fund are capped at its **free capital** — the balance less the seizure earmarked against inventory the vault still holds — so no keeper is ever paid out of collateral that backs an open estate. A fund holding nothing but earmarks pays nothing; the [reserve](insurance.md) may pay.

Four of these carry gates. The trigger tip is charged to the stop's owner — an owner whose collateral cannot cover it has the stop auto-canceled instead. The settlement tip is never paid for settling your own position, and after finalize only a bankrupt straggler earns it: a solvent one changes no ledger, so settling it is free. The unload reward's flat floor is granted only when the call unloads at least **$1,250** of notional (where 2 bp overtakes it) or clears the inventory, so slicing one unload into many earns no premium — the 2 bp rate itself is paid on any amount. The refresh bounty pays only when the call stores a *newer* Pyth update, at most once per **10 minutes** per pair, and only while the insurance fund and open-interest notional each exceed **$10,000** — it buys freshness for quiet pairs that matter, not a faucet. Every insurance-funded reward is all-or-nothing: skipped entirely, never paid partially, when the fund cannot cover it.

## How payouts are paid

Nothing above is pushed. Every amount the protocol owes a third party — the rewards in this table, integrator fees, the bug-bounty tax and relayer fees — is **accrued to the recipient's claimable balance on the pair** (`FeeAccrued(pairId, recipient, amount)` is emitted per accrual) and withdrawn with `claimFees()`; `claimableFees(address)` reads what is owed and the escrow's total. One claim per pair sweeps every kind of payout at once. For the cross-pair question — which pairs owe me enough to be worth a claim — the lens has `getClaimableFees(pairs[], who)` for a chosen list and `getClaimableFeesAll(who)` for every pair under the factory.

The pull design is what lets every payer stay safe: no liquidation, ADL step, price refresh, fill or relayed call ever runs a token transfer to an address outside the protocol, so a recipient that cannot receive USDC (a blacklisted keeper, a reverting contract) can block nothing — it simply never claims, and the cash sits reserved. The escrow's total is a liability the pair reserves alongside the deposits ledger and the insurance fund in every books-vs-cash check and in the terminal pot, and `claimFees()` stays open in every pair state, termination included.
