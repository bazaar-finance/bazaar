# Auto-Deleveraging

ADL is the backstop for the backstop: when the vault's inherited liquidation inventory threatens losses the insurance fund cannot absorb, the protocol force-closes the *most profitable, most leveraged counterparties* against that inventory — the standard perp-exchange socialization mechanism, implemented as a permissionless Dutch auction.

## Trigger & freeze

After every batch, liquidation, withdrawal, and ADL step, the pair computes the vault's **expected loss** (bankruptcy notional vs. current notional on the aggregate). When it exceeds **80% of the insurance fund**, ADL goes pending:

- All trading and order creation freeze; position-holders' withdrawals freeze (flat users may still exit — their cash can't affect scores or margin).
- The trigger price and funding index are snapshotted — the whole auction ranks against this frozen book, so a keeper's off-chain sort and on-chain execution agree; the target side is the *opposite* of the vault's inventory (the winners).
- Hysteresis: pending state only clears below **60%**, so the boundary can't flap.
- A hard deadline: pending for **24 hours** without resolution → the pair [terminates](termination.md) at a live price. ADL cannot become a limbo.
- If opposing liquidations flip the vault's inventory to the other side mid-auction, the target side is re-pointed and the price/funding snapshot re-taken — but the 24-hour clock is deliberately *not* reset, so repeated flips can never stall termination.

## The auction

Anyone may call `executeAdl(winners[], priceUpdate)` with up to 25 candidates, sorted by descending **ADL score**:

```
adlScore = positionPnL(at snapshot price) / collateral
```

— profit-to-collateral, so a 10× levered winner outranks a 2× one at equal profit. Collateral for scoring **excludes deposits made during the current ADL window** (epoch-tagged at deposit time): topping up mid-auction protects your margin but cannot re-rank you out of the queue. A withdrawn-to-zero winner scores effectively infinite — pure-profit claims stand first in line.

Eligibility decays like a Dutch auction: the score threshold starts at **25×** and decays quadratically to ~0 over **10 minutes**. The worst offenders are executable immediately; by minute ten, any profitable counterparty is.

## Settlement

Winners close at the **average bankruptcy price of the dead estates** — the price that makes the transfer exactly absorb the vault's book loss:

- Winners whose PnL at that price would be *negative* are skipped (never worse than break-even).
- Oversized winners are partially closed pro-rata.
- The winner's PnL credit is paid from the insurance fund, **capped at what the fund holds** — in the deep-insolvency tail, later (lower-scored) winners are haircut. Positions still close; the pair stays solvent by construction.
- Funding settles implicitly — the estates' accrued funding is embedded in the bankruptcy-derived price, and the winner's own funding tab rides inside their PnL. (A prior design double-counted this; a regression test pins the fix.)

The executor earns **0.1% of averted bad debt**. Every few closes the trigger condition is re-checked and the auction ends early once the fund is safe.
