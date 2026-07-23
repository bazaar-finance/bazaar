# Fees

All trading fees are charged per fill, on notional, deducted from each side's collateral. Rates are in *extended basis points* (EBP, 1/100 bp).

| Stream | Maker | Taker |
|---|---|---|
| Sequencer | 0.25 bp + $0.03 flat/side | **0.75 → 3.75 bp** by global bond utilization + $0.03 flat/side |
| Integrator | 0.25 bp | 0.25 bp |
| Insurance | 0.5 bp | dynamic — steers the fund to target; see below |

- **Dynamic taker sequencer fee**: 0.75 bp while global sequencer-bond utilization ≤ 50%, linear to 3.75 bp at ≥ 90% — congestion pays sequencers more and attracts more bonded capacity.
- **Dynamic taker insurance fee**: the base rate scales with the fund's [target ratio](insurance.md) — **0.5 bp** at the 2% minimum target, linear to **2 bp** at the 10% maximum. Below target it multiplies up sharply — base × (1 + 49 × shortfall²), hard-capped at **45 bp**; above target it discounts linearly to zero at 2× target. Risk-reducing size pays the base closing fee (or the dynamic rate, when that is even lower). Exact curve: `RiskParamsLib.getTakerInsuranceFeeEbp`.
- **Integrator fee**: each order carries an optional `integrator` address (frontend/aggregator) that earns its cut on every fill of that order. Referral revenue is protocol-native — see the [integrator guide](../guide/integrators.md).
- **Bug-bounty tax**: **1% of every fee stream** (sequencer, integrator, insurance) is skimmed to a bug-bounty address fixed at factory deployment — a standing white-hat budget that accrues automatically.

## Non-trading rewards

| Action | Reward | Paid from |
|---|---|---|
| Liquidation (per position) | max($0.10, 2 bp of notional) | insurance fund |
| ADL execution | 0.1% of averted bad debt | insurance fund |
| Omission challenge | 1% of min(batch, order) notional | sequencer bond |
| Stale-flag challenge | ½ × 1% of batch notional | sequencer bond |
| UMA termination proposer | 0.1% of the fund, capped $100, once per pair | insurance fund |

Fee payouts to sequencers/integrators/bounty that fail to transfer (e.g. USDC blacklist) are re-credited to the insurance fund rather than blocking settlement.
