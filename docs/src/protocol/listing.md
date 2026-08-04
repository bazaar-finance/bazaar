# Markets & Listing

Anyone can list a market. The factory gates listings through an UMA Optimistic Oracle assertion instead of a governance vote or admin whitelist.

## Flow

```
proposePairDeployment(baseFeedId, isContinuouslyTraded, totalAmount, description)
        │  pulls totalAmount USDC (≥ $4,000)
        │  ├─ $1,000 → UMA assertion bond (refunded to proposer on success)
        │  └─ ≥ $3,000 → escrowed insurance-fund seed
        ▼
   48-hour UMA liveness window (anyone can dispute)
        ▼
assertionResolvedCallback / settleDeploymentProposal
        ├─ truthful → EIP-1167 clone deployed, seeded, registered with
        │             sequencer + terminator; pairId = baseFeedId
        └─ disputed-and-false → bond lost to disputer, seed refunded
```

## What UMA verifiers check

The assertion text embeds seven objective criteria:

1. **Feed validity** — `baseFeedId` exists in Pyth's registry and matches the description.
2. **Trading-schedule flag** — `isContinuouslyTraded = true` only for genuinely 24/7 assets (crypto). Stocks, FX, and anything with market hours must be `false` (they get a 1.5× margin multiplier and the stale-oracle regime). Composites must be `false`.
3. **Eligible asset** — an actual tradeable asset or broad market index, USD-denominated.
4. **Composite quote leg** — non-USD quotes only through approved fiat legs (EUR, GBP, JPY, CHF, CAD, AUD, NZD, SEK, NOK, DKK, SGD, HKD, CNH).
5. **Linear, non-expiring spot exposure** — the test is: *could someone hold this asset indefinitely and experience exactly its price change?* Futures, options, bonds, leveraged/inverse products, volatility indices, rate products, pegged/rebased assets, and prediction markets are excluded.
6. **No 1:1 duplicates** — no wrapped BTC next to BTC, no S&P 500 ETF next to the index (propose the index itself), unless the underlying has no Pyth feed.
7. **Non-USD assets only as composites.**

A market whose pair was previously [terminated](termination.md) can be re-proposed.

`description` is the one proposer-controlled string in the claim, so it is bounded to **1–200 bytes** of a conservative ASCII subset — letters, digits, space, and `. , & / -`. Everything outside that set, including every non-ASCII byte, is rejected at submission. The claim is read by humans deciding whether to dispute, and the charset is what stops crafted text from escaping a delimiter, imitating the claim's `Field: value` syntax, opening a fake numbered criterion, or smuggling homoglyphs and invisible characters past them. Termination claims apply the [same discipline](termination.md#proposer-supplied-text) to their free-text fields.

## Non-USD assets: composite feeds

Assets quoted in another currency (e.g. DAX in EUR) trade against a **composite feed**: `price = base × quote` or `base ÷ quote` depending on the FX feed's direction. Composites are registered permissionlessly and idempotently in `BazaarOracle` (`registerComposite(baseId, quoteId, invertQuote)`); the composite ID — `keccak256(baseId ‖ quoteId ‖ invertQuote)` — is then used anywhere a feed ID is expected. A composite is only as fresh as its stalest leg, and both legs are confidence-checked.

## The only governance: swapping the UMA identifier

The **oracle address is immutable**. OOv3 generations at new addresses have always been ABI-breaking (v1→v2→v3), so no on-chain upgrade path could adopt one anyway — and a mutable oracle pointer's worst case is a malicious oracle activating through an unwatched governance slot, which is protocol-wide adjudication capture. What UMA actually changes over time is the **identifier whitelist** (entries added and removed by governance vote, on the same oracle address), so that is the axis Bazaar's governance track upgrades. An oracle-contract-level death — deregistration, the DVM abandoning the generation, neither of which has ever happened to a UMA oracle — means a factory redeploy; existing pairs keep their non-UMA termination paths.

`proposeUmaIdentifierUpgrade(newIdentifier)` — a $5,000 bond (five times listings') and a **2-day** liveness window. The window matches listings' — the same watchers review both tracks — and it is the only point at which a wrong-but-whitelisted identifier can be stopped, since the identifier decides how UMA voters adjudicate every future listing and termination; the extra friction lives in the bond and the activation timelock. The candidate is validated against UMA's **live IdentifierWhitelist** before the bond moves — resolved the same way OOv3 resolves it (`finder → IdentifierWhitelist → isIdentifierSupported`) — so a poisoned identifier can never enter the pipeline. The genesis identifier is validated the same way **in the constructor**: a wrong value fails the deploy, not the deployed protocol. One pending upgrade at a time. In-flight assertions carry the identifier they were made under (OOv3 stores it per assertion), so an upgrade cannot strand them. The bond, like every other in the protocol, is a floor rather than a fixed figure — quote `requiredIdentifierUpgradeBond()`, which tracks UMA's own owner-settable minimum upward.

**The candidate must also be named `ASSERT_TRUTH…`.** UMA's whitelist is a "some UMIP defines this" list, not a "safe for adjudicating truth assertions" list, so the whitelist check alone cannot reject a *price feed* — and OOv3 resolves an assertion TRUE on a DVM price of exactly `1e18`. Some whitelisted identifiers can return it: UMIP-29's EURUSD and CHFUSD are 18-decimal FX feeds read off a live source whose voters never look at ancillary data, so at parity they resolve to exactly `1e18` and decide every dispute in advance — auto-approving everything at parity, and auto-rejecting everything anywhere else, which makes disputing a profitable unconditional veto. Others (dead-source feeds like FEIUSD) are unvotable at all, so the DVM request rolls until it is deleted and `settleAssertion` reverts forever. Requiring the first 12 bytes to be ASCII `ASSERT_TRUTH` makes that whole class unrepresentable while staying forward-compatible: UMA versions these identifiers by suffix, so a conventionally-named successor is adoptable with no code change. The accepted tradeoff is that a successor named off-convention would need a factory redeploy — a loud, monitored failure, rather than the silent and unrecoverable one a wrong adjudicator produces.

The protocol currently deploys under **`ASSERT_TRUTH2`**. This is exactly why the identifier is a governed parameter and not derived from the oracle: OOv3's own `defaultIdentifier` constant is `ASSERT_TRUTH`, which UMA has since de-whitelisted in favour of the successor on the *same* oracle deployment — deriving from it would point the protocol at a dead identifier from block one.

Approval does not swap the identifier — it queues the upgrade behind a further **14-day** activation timelock (`IDENTIFIER_UPGRADE_TIMELOCK`). Until anyone calls `activateIdentifierUpgrade()` after the timelock, the incoming identifier governs nothing, so traders who distrust it have a guaranteed exit window (insurance-LP withdrawals remain subject to their 20-day cooldown, which outlasts the timelock). The whitelist check runs again at activation; an identifier de-whitelisted during the 16 days *cancels* the upgrade and keeps the incumbent, so a dud can never brick governance. (The factory also calls `syncUmaParams` at construction and activation to warm OOv3's identifier cache — a first-assertion gas nicety only. The cache is **not** a liveness guarantee: `syncUmaParams` is public and overwrites with the live value, so anyone can flip a de-whitelisted identifier's cache to false. Nothing in Bazaar relies on it — submissions under a dead identifier are prevented upstream by the gates and the routing below.)

De-whitelisting creates a **degraded mode**: an assertion under the dead identifier would be **undisputable** — the DVM re-checks the live whitelist on every dispute — and could also hard-revert outright once anyone re-syncs OOv3's public cache. The protocol **fails closed** instead of failing open: while `umaIdentifierIsLive()` is false, new pair listings and both UMA termination proposals revert at submission, so nothing enters an undisputable pipeline (non-UMA termination — insurer vote, stale price, insolvency — is unaffected, and `umaIdentifierIsLive()` doubles as the one-call monitoring endpoint). The identifier-upgrade path is the deliberate exception — it is the repair path — and in degraded mode it **routes its assertion under the proposed (validated-live) identifier** rather than the dead incumbent, so the recovery proposal itself remains disputable instead of becoming first-proposer-wins.

**There is no rollback lever, deliberately.** Reverting to a predecessor identifier would require that predecessor to still be whitelisted, but a full upgrade cycle (2-day liveness + 14-day timelock = 16 days) outlasts the ~7.7-day coexistence window UMA left between whitelisting a successor and retiring its predecessor in its only observed migration — so a rollback target is already gone by the time it could be used. Nor would a rollback address the case that would most want one: an identifier that is semantically wrong but still *whitelisted*, where the incumbent is exactly what you would be rolling back to. A permissionless writer of `umaIdentifier` guarding a state that cannot be reached is a liability, not insurance. The identifier-upgrade track is the sole recovery route, and the fail-closed gates hold listings and terminations meanwhile — so a slow recovery costs liveness, never funds.

Only one upgrade proposal exists at a time, and UMA returns the bond to the proposer *before* firing its resolve callback — so a proposer who becomes unable to receive USDC after proposing makes settlement revert, leaving the slot occupied with nothing able to clear it. `expireStuckIdentifierUpgradeProposal()` bounds that: anyone may discard a proposal that genuinely cannot settle. It attempts settlement first, so a still-resolvable proposal is never thrown away, and the assertion is left live on the oracle so the winning party can still collect their bond later.

For an **undisputed** proposal no waiting is needed beyond liveness, because a failure there is proof rather than inference: past `expirationTime`, OOv3's undisputed branch has only the bond payout and the factory's own (non-reverting) callback left, so a failed settlement can only be a blocked payout. A **disputed** proposal is the one case that needs a timer — being unsettleable is expected while the DVM votes, and that state is not readable from the factory (`hasPrice`/`getPrice` are `onlyRegisteredContract`). It waits out a further `DVM_DISPUTE_GRACE` of **14 days**, which stops a dispute from becoming a cheap veto: without it, any disputer could discard the proposal the moment liveness ended regardless of how the vote later went. The 14 days are derived from mainnet VotingV2's own limits: a commit+reveal round is 48 h (`phaseLength` = 24 h) and a request is deleted once it rolls past `maxRolls` = 4, giving it five rounds — 10 days — plus up to one round of enqueue lead, so 12 days is the longest a dispute can legitimately take. That bound is a property of the DVM rather than of what is being proposed, which is why the deployment track shares the same constant.

Deployment proposals get the identical escape hatch for the identical reason: `expireStuckDeploymentProposal(pairId)` releases a `pairId` whose assertion can no longer settle — otherwise a blacklisted deployer or an undeliverable disputer payout would occupy that asset's listing slot forever — and credits the escrowed seed to `seedRefundOwed`, which its owner collects with `claimSeedRefund()`. The credit is pulled rather than pushed because the crediting happens inside UMA's settlement callback, where a failing transfer would take settlement down with it.
