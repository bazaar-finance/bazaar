# Fees

All trading fees are charged per fill, on notional, deducted from each side's collateral. Rates are in *extended basis points* (EBP, 1/100 bp).

| Stream | Maker | Taker |
|---|---|---|
| Insurance | 0.5 bp | dynamic — steers the fund to target; see below |
| Integrator | 0.25 bp | 0.25 bp |

- **Dynamic taker insurance fee**: the base rate scales with the fund's [target ratio](insurance.md) — **0.5 bp** at the 2% minimum target, linear to **2 bp** at the 10% maximum. Below target it multiplies up sharply — base × (1 + 49 × shortfall²), hard-capped at **45 bp**; above target it discounts linearly to zero at 2× target. Risk-reducing size pays the base closing fee (or the dynamic rate, when that is even lower). Exact curve: `RiskParamsLib.getTakerInsuranceFeeEbp`.
- **Integrator fee**: each order carries an optional `integrator` address (frontend/aggregator) that earns its cut on every fill of that order. Referral revenue is protocol-native — see the [integrator guide](../guide/integrators.md).
- **Bug-bounty tax**: **1% of every fee stream** (insurance, integrator) is skimmed to a bug-bounty address fixed at factory deployment — a white-hat budget that accrues automatically from the first fill.

## Non-trading rewards

| Action | Reward | Paid from |
|---|---|---|
| Liquidation (per position) | max($0.10, 2 bp of notional) | insurance fund |
| Terminal settlement (per position) | max($0.10, 2 bp of notional) | the settled position's own remaining collateral; insurance only when its own loss wiped it out |
| ADL execution | 0.1% of averted bad debt | insurance fund |
| Trigger execution (per fired stop) | $0.25 (`TRIGGER_TIP`) | the stop owner's collateral, like a trading fee |
| Vault unload | max($0.10, 2 bp of unloaded notional) | insurance fund |
| Price refresh | $0.25 (`REFRESH_BOUNTY`) | insurance fund |
| UMA termination proposer | 0.1% of the fund, capped $100, once per pair | insurance fund |

Three of these carry gates. The trigger tip is charged to the stop's owner — an owner whose collateral cannot cover it has the stop auto-canceled instead. The unload reward pays only when at least **$100** of notional actually unloads, so dust unloads can't farm the flat minimum out of the fund. The refresh bounty pays only when the call stores a *newer* Pyth update, at most once per **10 minutes** per pair, and only while the insurance fund and open-interest notional each exceed **$10,000** — it buys freshness for quiet pairs that matter, not a faucet.

Fee payouts to integrators or the bug-bounty address that fail to transfer (e.g. USDC blacklist) are re-credited to the insurance fund rather than blocking settlement.
