// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title ClaimTextLib
/// @notice External library holding the static text of the UMA claims Bazaar asserts: the
///         numbered eligibility checks of a pair listing, the validation steps of an identifier
///         upgrade, and the reason categories and validation steps of a termination proposal.
///         Linked as an external library so the text's bytecode lives outside the EIP-170
///         budgets of BazaarFactory and BazaarPairTerminator, which write each claim's
///         contract-specific parts (chain ID, feed IDs, pair and assertion IDs, the fenced
///         proposer text) and concatenate these blocks between them.
library ClaimTextLib {
    /// @notice The checks UMA verifiers apply to a pair listing claim, numbered (1) to (9), and
    ///         the rule that the assertion is invalid if any fails. The checks refer to the asset
    ///         description, feed IDs and trading flag the factory writes ahead of this block.
    /// @return The numbered checks and the invalidity rule, as UTF-8 text
    function listingChecks() external pure returns (bytes memory) {
        return abi.encodePacked(
            " UMA VERIFIERS MUST CHECK ALL OF THE FOLLOWING: "
            "(1) FEED VALIDITY: Every Pyth feed ID listed above (for composite proposals, BOTH the base leg and the quote leg) "
            "corresponds to an ACTIVE Pyth Core price feed on the chain identified above, and the base feed matches the asset description stated above. "
            "Pyth Core and Pyth Pro are separate products with different feed ID namespaces; only Pyth Core feeds are readable by "
            "the Pyth Core oracle contract identified above. Verify via the Pyth Core price feed registry. "
            "The base feed (for composite proposals, the base leg) must be the asset's PRIMARY trading-session feed: "
            "feeds restricted to an extended or partial trading session - e.g., US equity pre-market, after-hours, or overnight "
            "variants, whose Pyth symbols carry suffixes such as .PRE, .POST, or .ON - are INVALID whenever a regular-session "
            "feed for the same asset exists. " "(2) TRADING SCHEDULE: The 'continuously traded' flag is accurate. "
            "'true' means the asset trades 24/7 with no scheduled breaks (e.g., BTC, ETH). "
            "'false' means the underlying asset has defined trading hours. "
            "Composite proposals MUST be marked 'false': FX rates are not live 24/7, so no composite pair is continuously traded. "
            "(3) ELIGIBLE ASSET: The oracle references an actual tradeable financial asset, or a broad market price index with liquid "
            "investable trackers (e.g., index funds or ETFs), whose resulting price is denominated in USD: "
            "either the base feed is quoted directly in USD, or the proposal is a composite whose quote leg converts the base feed's quote currency to USD. "
            "A spot FX rate quoted in USD (e.g., EUR/USD) IS an eligible single-feed asset: holding the foreign currency gives exactly the rate's "
            "change, and the interest differential is no part of the feed. FX markets close over the weekend, so its 'continuously traded' flag must be 'false'."
            " (4) QUOTE LEG CORRECTNESS (composite proposals only): The quote leg must be the Pyth FX feed for EXACTLY the currency "
            "the base feed is quoted in (e.g., a stock quoted in JPY requires the USD/JPY FX feed; an FX feed for any other currency is INVALID). "
            "The 'quote leg inverted' flag must be accurate: 'false' means the FX feed reports US dollars per one unit of the base feed's "
            "quote currency (e.g., GBP/USD); 'true' means the FX feed reports units of the base feed's quote currency per one US dollar (e.g., USD/JPY). "
            "ELIGIBLE BASE-FEED CURRENCIES: the base feed's quote currency MUST be one of: EUR, GBP, JPY, CHF, CAD, AUD, NZD, SEK, NOK, DKK, SGD, HKD, CNH, CNY, KRW, TWD. "
            "A proposal whose base feed is quoted in ANY other currency is INVALID. "
            "Assets quoted in onshore CNY must use the offshore USD/CNH FX feed as the quote leg, not the onshore USD/CNY feed."
            " (5) LINEAR, NON-EXPIRING ASSETS ONLY: The feed must track the SPOT price of an asset (or broad market index level) that "
            "(a) never expires, settles, or resolves, and (b) gives a holder linear (delta-one) exposure: one unit held gains exactly as much "
            "when the price rises as it loses when the price falls, with no built-in leverage, optionality, decay, or price management. "
            "Apply this test: 'could someone hold this asset indefinitely and experience exactly its price change, and nothing else?' "
            "For a broad market index, apply the test to its investable trackers instead. If the test fails, the assertion is INVALID. "
            "Ordinary cash dividends do not violate this check, provided the dividend is not the instrument's primary source of return "
            "or a mechanism used to manage its price. "
            "NOT ELIGIBLE under this check (non-exhaustive): futures or any instrument with an expiry, settlement, or resolution date; "
            "options, warrants, or convertibles; bonds, preferred stocks, and other fixed-income or yield-based instruments; "
            "leveraged or inverse products (e.g., 3x ETFs, leveraged tokens); "
            "volatility indices or other statistical indices that do not represent a holdable basket of assets; "
            "yield-, funding-, or interest-rate-linked products; "
            "assets pegged, rebased, or actively managed toward a target price (e.g., stablecoins); "
            "prediction-market outcomes; economic data series (e.g., CPI, inflation rate, interest rates, GDP). "
            "(6) NO MIRRORED DUPLICATES: This check judges derivative trackers only - depositary receipts and multi-market listings "
            "of the SAME security are judged under check (8). "
            "The oracle feed must NOT track an asset whose sole purpose is tracking another underlying asset or index 1:1. "
            "Such assets include but are not limited to wrapped tokens, 1:1 exchange traded funds, synthetic derivatives, perpetual futures, "
            "and other instruments that track the price of an underlying asset or index without significant basis risk "
            "(e.g., reject a wrapped BTC feed; reject an S&P 500 ETF feed - propose the index itself instead). "
            "EXCEPTION: a 1:1 tracker IS eligible if the underlying asset or index it tracks has NO active Pyth Core price feed on the chain identified above at proposal time "
            "(verify via the Pyth Core feed registry) - the tracker is then the only way to list the exposure and no duplicate pair can exist. "
            "The tracker must still pass every other check, including check (5). "
            "However, assets with genuinely distinct price behavior ARE eligible (e.g., a single stock vs. an index that contains it). "
            "(7) NON-USD ASSETS: Assets quoted in non-USD currencies are NOT eligible as single-feed proposals; "
            "they are ONLY eligible as composite proposals satisfying checks (1) through (4). "
            "(8) SAME SECURITY IN MULTIPLE MARKETS: Where the SAME security is reachable through more than one Pyth Core feed - a US depositary "
            "receipt (ADR) alongside the foreign ordinary share it represents, or one share class listed on two exchanges in different currencies - "
            "only the USD-quoted Core feed is eligible, because listing it requires no FX leg. If no USD-quoted Core feed exists for that security, "
            "the remaining listings are peers and any of them may be proposed as a composite. "
            "Separately listed share classes of ONE issuer are the SAME security here unless they carry materially different economic entitlements "
            "(e.g., different dividend or liquidation rights, or exposure to different parts of the business) and their prices diverge persistently "
            "rather than tracking within a narrow arbitraged band; classes differing only in voting rights or denomination are NOT distinct - a "
            "perpetual conveys no vote - so only one is eligible: the class with the greater trading volume on its primary exchange. "
            "Dual-listed company structures - two SEPARATE legal entities holding stapled economic interests, whose shares trade at a persistent "
            "and independently varying spread - are distinct assets, and each is eligible. "
            "(9) NO PENDING TERMINATION EVENT: No event that would be valid grounds for terminating the pair is already officially announced "
            "for the asset or for any feed listed above - a scheduled Pyth feed decommission, a confirmed delisting, a merger or acquisition with a "
            "scheduled closing, a bankruptcy, a split, reverse split, spinoff, rights offering or one-time distribution exceeding 5% of the asset's price, "
            "a redenomination, or an index re-basing or methodology change. A market that would have to be terminated as soon as it opens is INVALID; "
            "propose it once the event has passed. " "Assertion is INVALID if ANY of the above checks fail."
        );
    }

    /// @notice The validation steps of an identifier-upgrade claim: the proposed identifier is
    ///         whitelisted and suited to truth assertions, and the upgrade is necessary.
    /// @return The validation steps and the invalidity rule, as UTF-8 text
    function identifierUpgradeHowToValidate() external pure returns (bytes memory) {
        return abi.encodePacked(
            " HOW TO VALIDATE: "
            "NOTE: Identifiers are displayed as hex-encoded bytes32 values. To verify, convert the hex to a UTF-8 string. "
            "UMA voters should verify that: "
            "(1) The proposed identifier is approved and active on UMA's IdentifierWhitelist, and is appropriate for "
            "adjudicating free-form truth assertions of the kind Bazaar submits (pair listings and market terminations). "
            "(2) The upgrade is necessary: the current identifier is deprecated, de-whitelisted, scheduled for removal, "
            "or otherwise unsuitable for those assertions. "
            "Assertion is INVALID if: the proposed identifier is not approved, is not suited to truth assertions, "
            "or there is no need for the change (the current identifier remains functional and appropriate)."
        );
    }

    /// @notice The reason categories a termination proposal declares, (1) to (4), each with the
    ///         grounds it accepts. The certainty each future-dated category demands exists
    ///         because acceptance is irrevocable: an event that is later cancelled still ends
    ///         the market.
    /// @return The reason categories and the grounds each accepts, as UTF-8 text
    function terminationReasons() external pure returns (bytes memory) {
        return abi.encodePacked(
            " VALID TERMINATION REASONS (the proposal declares one; the evidence must establish it): "
            "(1) ORACLE DECOMMISSION: The Pyth feed(s) listed above have ceased publishing updates, are scheduled to be decommissioned, or will cease publishing updates. For a composite (two-leg) feed, decommissioning of EITHER leg - the base leg or the quote/FX leg - is sufficient grounds, since the pair cannot be priced in USD without both legs. "
            "(2) ASSET CESSATION: The underlying asset has been or will be delisted from the exchange tracked by the oracle feed, rendering the feed invalid (even if the asset continues trading OTC). Includes: exchange delisting, merger/acquisition (cash or stock conversion), bankruptcy, or indefinite regulatory halt. "
            "A cessation that has not yet happened counts only once it is officially confirmed with a fixed effective date - an exchange-published delisting date, a merger or acquisition that has received shareholder and regulatory approval and has a scheduled closing date, a court-confirmed bankruptcy plan; an event that is merely proposed, announced but not yet approved, or contested is NOT sufficient grounds. "
            "(3) STRUCTURAL CHANGE: The asset or index will undergo a corporate, administrative, or methodological event that makes its price series discontinuous - the price published after the event is not comparable to the price before it. "
            "The event must be officially scheduled by the issuer, index provider, or project, with a fixed record, effective, or ex-date; a contemplated, proposed, or still-pending-approval event is NOT sufficient grounds. "
            "Examples (non-exhaustive): splits, reverse splits, spinoffs, rights offerings, special dividends or other one-time distributions exceeding 5% of the asset's price, "
            "token redenominations or migrations, index re-basings or methodology changes to the published level, and redenomination of the quote currency of a composite pair. "
            "NOT valid: regular cash dividends, and market-driven price moves of ANY expected size (e.g., earnings, court rulings, regulatory news, macroeconomic events) - anticipated volatility is tradeable risk, not a structural discontinuity. "
            "(4) PYTH CONTRACT MIGRATION: The Pyth oracle contract at the address listed above has been deprecated or is migrating to a new contract address, rendering the pair unable to fetch prices."
        );
    }

    /// @notice The validation steps of a termination claim. Every figure is rendered from the
    ///         argument the terminator passes, read from the constant that enforces it, so the
    ///         text cannot drift from the contract.
    /// @param livenessHours The proposal liveness in hours: the earliest cutoff acceptance alone
    ///        enforces after submission
    /// @param voteLeadHours The earliest cutoff after submission the insurers' vote may enforce,
    ///        in hours
    /// @param haltLeadSeconds How long before the cutoff the pair halts, in seconds
    /// @param windowSeconds How far before the cutoff the window its settlement print must fall
    ///        in opens, in seconds
    /// @param cutoffLeadSeconds The lead a cutoff already past, or sooner than this, is moved
    ///        to after acceptance, in seconds
    /// @param graceHours How long a settlement print is awaited before the pair settles at its own
    ///        last stored price, counted from the cutoff or, for a pair the vote halted, from when
    ///        the assertion's result is known if that is later, in hours
    /// @param verdictGraceDays How long after submission a pair the vote halted waits for this
    ///        assertion's result before settling without one, in days
    /// @param voterLockDays How long after the settlement the voters of a halt the assertion did
    ///        not uphold may not redeem, in days
    /// @param levyFloorPercent The least share of their voted shares those voters forfeit when the
    ///        assertion has no result, in percent
    /// @param sampleCount How many prints the median a halt the assertion did not uphold settles
    ///        at is taken over
    /// @param sampleSpacingMinutes How far apart in minutes those prints are taken, at least
    /// @return The validation steps with each figure rendered, as UTF-8 text
    function terminationHowToValidate(
        uint256 livenessHours,
        uint256 voteLeadHours,
        uint256 haltLeadSeconds,
        uint256 windowSeconds,
        uint256 cutoffLeadSeconds,
        uint256 graceHours,
        uint256 verdictGraceDays,
        uint256 voterLockDays,
        uint256 levyFloorPercent,
        uint256 sampleCount,
        uint256 sampleSpacingMinutes
    ) external pure returns (bytes memory) {
        string memory liveness = Strings.toString(livenessHours);
        string memory voteLead = Strings.toString(voteLeadHours);
        string memory halt = Strings.toString(haltLeadSeconds);
        string memory window = Strings.toString(windowSeconds);
        string memory lead = Strings.toString(cutoffLeadSeconds);
        string memory grace = Strings.toString(graceHours);
        string memory verdictGrace = Strings.toString(verdictGraceDays);
        string memory voterLock = Strings.toString(voterLockDays);
        string memory levyFloor = Strings.toString(levyFloorPercent);
        return bytes.concat(
            abi.encodePacked(
                " HOW TO VALIDATE: "
                "Identify the pair's asset from the feed IDs listed above, using the Pyth price feed registry: the evidence must concern that asset. "
                "The declared reason category above is the one this proposal claims, and the evidence must establish it. "
                "Grounds that also fit another category do not invalidate the proposal: a delisting usually also ends the feed, and every category is held to the same cutoff floor. "
                "UMA voters should verify the proposer's evidence (the bracket-fenced final section) by checking official sources: "
                "(1) For oracle issues, check the Pyth Network status page and feed registry for the feed IDs listed above. "
                "(2) For asset cessation, verify with official exchange notices or regulatory filings. "
                "(3) For structural changes, verify with the company's investor relations page, the index provider's or token project's official announcements, exchange bulletins, or regulatory filings. "
                "(4) For Pyth contract migration, verify via Pyth Network official announcements that the oracle contract is being deprecated or migrated. "
                "(5) Confirm the proposed last trading timestamp is reasonable: it should be at or right before the last moment the asset can trade under existing (pre-event) conditions, but neither unnecessarily early nor later than the event requires. "
                "If the event has already occurred, the earliest timestamp acceptance alone can enforce (",
                liveness,
                " hours after submission) is the reasonable choice. "
            ),
            abi.encodePacked(
                "The pair halts trading ",
                halt,
                " seconds before the scheduled timestamp and settles at the first Pyth price update published within the last ",
                window,
                " seconds up to it; a timestamp already past, or less than ",
                lead,
                " seconds away, when the proposal is accepted is moved to ",
                lead,
                " seconds after acceptance. If nobody supplies that update within ",
                grace,
                " hours of the scheduled timestamp, or none exists, the pair settles at its own last stored price. "
            ),
            abi.encodePacked(
                "This proposal also opens a vote of the holders of the pair's insurance fund shares: if holders of 60 percent of the shares vote for it, the pair halts at the proposed timestamp whether or not this assertion has resolved. "
                "A proposed timestamp sooner than ",
                liveness,
                " hours after submission, down to ",
                voteLead,
                " hours, takes effect as proposed only through that vote: this assertion cannot be accepted before it, so if nobody votes it through, acceptance moves it as described above for a timestamp already past. "
                "A pair the vote halted settles under this assertion's result: resolved TRUE, it settles as described above, except that the ",
                grace,
                " hours run from the end of this assertion's liveness, or, if it is disputed, from the on-chain recording of its result, when that is later than the timestamp; resolved FALSE, it settles instead at the median of ",
                Strings.toString(sampleCount),
                " Pyth price updates, the first published at or after the timestamp and each later one the first published at least ",
                Strings.toString(sampleSpacingMinutes),
                " minutes after the one before it, and the holders who voted for it forfeit half of their voted shares. "
                "Without a result ",
                verdictGrace,
                " days after submission it settles as for FALSE and those holders forfeit half of the dissenting fraction of their voted shares, never less than ",
                levyFloor,
                " percent of them, instead; in both cases they may not redeem for ",
                voterLock,
                " days after the settlement. "
                "ACCEPTANCE IS FINAL: an accepted proposal cannot be withdrawn, and its cutoff can never be delayed or cancelled. "
                "It can only move earlier: a later UMA proposal with an earlier cutoff, judged on its own event, or a vote of the pair's insurance fund holders may bring it forward, and the protocol's stale-feed and insolvency paths end the pair at once. "
                "An event that may still be cancelled or rescheduled therefore makes the assertion INVALID. "
                "Assertion is INVALID if: the evidence does not establish the declared category, the event is not confirmed as that category requires, evidence is fabricated or unverifiable, or the timestamp is unreasonable. "
            )
        );
    }
}
