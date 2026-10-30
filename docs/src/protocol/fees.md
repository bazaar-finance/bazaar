# Fees

All trading fees are charged per fill, on notional, deducted from each side's collateral. Rates are in *extended basis points* (EBP, 1/100 bp).

| Stream | Maker | Taker |
|---|---|---|
| Insurance | 0.5 bp | dynamic — steers the fund to target; see below |
| Integrator | 0.25 bp | 0.25 bp |

- **Dynamic taker insurance fee**: the base rate scales with the fund's [target ratio](insurance.md) — **0.5 bp** at the 2% minimum target, linear to **4 bp** at the 10% maximum. Below target it multiplies up sharply — base × (1 + 49 × shortfall²), hard-capped at **50 bp**. The base rate is a floor: at or above target the fee stays there and never discounts, however overfull the fund is. Risk-reducing size pays the base rate, so closing is never more expensive than opening. Exact curve: `RiskParamsLib.getInsuranceFeeRates`.
- **Integrator fee**: each order carries an optional `integrator` address (frontend/aggregator) that earns its cut on every fill of that order. Referral revenue is protocol-native — see the [integrator guide](../guide/integrators.md).
- **Bug-bounty tax**: **1% of the insurance and integrator fee streams** is skimmed into the claimable balance of a bug-bounty address fixed at factory deployment — a white-hat budget that accrues automatically from the first fill. The same address receives the insurance shares an [insurer-vote termination](termination.md) levy forfeits, redeemable like any holder's once the pair has settled.

## Non-trading rewards

| Action | Reward | Funded from |
|---|---|---|
| Liquidation | $0.05 for each position seized or [deferred liquidation](liquidations.md) newly recorded, or max($0.05, 2 bp of the notional it retires) for a seizure that nets against the vault's inventory; the call's inline unload adds whatever 2 bp of what it sells exceeds those rewards beyond the nettings' 2 bp; an account whose position is worth less than $5 counts for at most its own equity | insurance fund (free capital) |
| ADL execution | 0.1% of averted bad debt, plus max($0.05, 2 bp at the mark of the notional the batch retires with it) for every deferred account the batch seizes — $0.05 alone for one it moves into the inventory — the $0.05 limited the same way below $5 | insurance fund (free capital) |
| Trigger execution | the bounty the owner attached to the order, paid in proportion to the size each execution fills (the remainder on completion or resting); an execution in the creation block of an order the stale fallback left unarmed pays the owner instead | the owner's wallet, escrowed when the order was placed — never collateral |
| Vault unload | 2 bp of unloaded notional; a $0.25 floor when ≥ $1,250 unloads or the inventory clears | insurance fund (free capital) |
| Price refresh | $0.10 (`REFRESH_BOUNTY`) | insurance fund (free capital) |
| Terminal settlement (per position settled for someone else) | up to $0.05 (`TERMINAL_SETTLEMENT_TIP`) | before finalize: the settled position's remaining collateral, insurance topping up for positions worth at least $5; after finalize: the insurers' residual, bankrupt stragglers of at least $5 only |
| UMA termination proposer | 0.1% of the fund, capped $100, once per pair | insurance fund (free capital) |
| Meta-transaction relay (per action) | the signed `relayerFee`, ≤ $1 | the signer's wallet or payout |

Rewards funded from the insurance fund are capped at its **free capital** — the balance less the seizure earmarked against inventory the vault still holds — so no keeper is ever paid out of collateral that backs an open estate. A fund holding nothing but earmarks pays nothing; the [reserve](insurance.md) may pay.

Four of these carry gates. The trigger bounty is the owner's own money, escrowed from their wallet when the order is placed; an execution earns only the share it fills, and whatever is left when the order ends unexecuted returns to the owner. The settlement tip is never paid for settling your own position, and after finalize only a bankrupt straggler earns it: a solvent one changes no ledger, so settling it is free. The unload reward's flat floor is granted only when the call unloads at least **$1,250** of notional (where 2 bp overtakes it) or clears the inventory, so slicing one unload into many earns no premium — the 2 bp rate itself is paid on any amount. The refresh bounty pays only when the call stores a *newer* Pyth update, and only while the fund's free capital exceeds **$5,000**. How often it pays follows what the fund has at stake: at most once per **5 minutes** while the vault holds at least **$1,250** of inventory, since the health check a refresh runs is what opens an ADL window when that inventory drifts past the trigger on a book too thin to trade, and otherwise once per **day**, a heartbeat that keeps a quiet pair's stored price well inside the 21-day [stale-termination](termination.md) line. Inventory rather than open interest sets the cadence because inventory costs something to create: a long and a short parked in two wallets clear any open-interest floor for nothing but the margin they lock, and would otherwise draw the fast cadence from a dormant pair indefinitely. It buys freshness where it protects someone, not a faucet.

The two flat keeper payouts also shrink for positions worth less than the **$5** order minimum: there the $0.05 liquidation reward is capped at the account's own equity, and the settlement tip at what the position's own collateral covers. The order minimum bounds orders, not positions. A reduce sized just under the position, or a small partial fill of a resting order, can leave a position that small with no collateral at no cost, so an uncapped flat payout would pay out of insurance once per such account. At $5 and above nothing changes, because the maintenance margin on such a position already covers either payout.

What a fund that cannot pay in full does depends on the reward. The liquidation, unload, ADL and proposer rewards are **trimmed** to the free capital that is there — the work is done either way, and a keeper who seized a position or sold inventory has already committed the gas, so paying what can be paid keeps the incentive pointing the right way. The two rewards that gate instead of trimming are the ones whose work is optional: the refresh bounty simply does not arm below its $5,000 floor, and the terminal settlement tip's insurance leg is all-or-nothing on top of whatever the settled position itself paid.

## How payouts are paid

Nothing above is pushed. Every amount the protocol owes a third party — the rewards in this table, integrator fees, the bug-bounty tax and relayer fees — is **accrued to the recipient's claimable balance on the pair** (`FeeAccrued(pairId, recipient, amount)` is emitted per accrual) and withdrawn with `claimFees()`; the lens's `claimableFees(pair, who)` reads what is owed and the escrow's total. One claim per pair sweeps every kind of payout at once. For the cross-pair question — which pairs owe me enough to be worth a claim — the lens has `getClaimableFees(pairs[], who)` for a chosen list and `getClaimableFeesAll(who)` for every pair under the factory.

The pull design is what lets every payer stay safe: no liquidation, ADL step, price refresh, fill or relayed call ever runs a token transfer to a third party, so a recipient that cannot receive USDC (a blacklisted keeper, a reverting contract) can block nothing — it simply never claims, and the cash sits reserved. The escrow's total is a liability the pair reserves alongside the deposits ledger and the insurance fund in every books-vs-cash check and in the terminal pot, and `claimFees()` stays open in every pair state, termination included.
