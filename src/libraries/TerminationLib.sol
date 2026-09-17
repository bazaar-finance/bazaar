// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BazaarMathLib} from "./BazaarMathLib.sol";
import {RiskParamsLib} from "./RiskParamsLib.sol";

/// @title TerminationLib
/// @notice External library holding the finalize step of pair termination. Runs via DELEGATECALL.
///         Termination is two-stage: the settlement price is fixed first, positions are settled
///         at it one by one (CollateralLib.settleTerminalPositions), and this finalize then
///         freezes the two payout ratios every terminal withdrawal is paid at.
/// @dev The total owed to traders is not summed over accounts; it falls out of the ledger
///      identity the live protocol maintains at every step:
///
///          Σ bucket.collateral + Σ unrealizedPnl(P, F) + estateValue(P, F) = D + deficit
///
///      Settling a position moves its unrealized PnL into its bucket (or, for a winner, into a
///      registered claim; or, beyond its collateral, into the bad-debt tally) without touching D.
///      Once every position is settled the unrealized term is zero, so
///
///          Σ collateral + Σ claims = D + deficit + badDebt − estateValue(P, F)
///
///      exactly. That figure is what the pot has to cover. Principal is senior: it is paid first,
///      registered profit claims share what remains at one ratio, and the insurance fund is
///      whatever is left after both — so insurance absorbs bad debt, the pre-termination
///      deficit and the estate's loss before any winner is cut, and inherits the estate's gain.
library TerminationLib {
    // -------------------- Errors --------------------

    error TerminationLib__TerminationPriceRequired();
    error TerminationLib__BalanceOfFailed();

    // -------------------- Events --------------------

    /// @notice Emitted once, at finalize.
    /// @param owedToTraders Σ collateral + Σ registered claims, as derived from the ledgers
    /// @param registeredClaims Σ registered winner profit
    /// @param badDebt Σ settled losses beyond collateral at finalize
    /// @param estateValue The vault's inherited inventory valued at the settlement price
    /// @param pot Distributable cash: the USDC balance less the fee escrow
    /// @param principalRatioBp Cash paid per unit of bucket collateral
    /// @param profitRatioBp Cash paid per unit of registered claim
    /// @param insuranceFundBalanceAfter The insurers' residual
    /// @param sweepComplete False when finalize ran through the escape hatch with positions open
    event PairTerminated(
        bytes32 indexed pairId,
        uint256 settlementPrice,
        uint256 owedToTraders,
        uint256 registeredClaims,
        uint256 badDebt,
        int256 estateValue,
        uint256 pot,
        uint256 principalRatioBp,
        uint256 profitRatioBp,
        uint256 insuranceFundBalanceAfter,
        bool sweepComplete,
        uint256 timestamp
    );

    // -------------------- Functions --------------------

    /// @notice Finalizes a termination: retires the vault's inherited inventory, derives the
    ///         total owed to traders, and freezes the principal and profit payout ratios.
    /// @dev Called via DELEGATECALL from BazaarPair._terminatePair. Rewrites the two vault
    ///      ledgers to their terminal meaning: totalCollateralDeposited becomes the principal
    ///      the pot owes (Σ collateral), insuranceFundBalance becomes the residual after every
    ///      trader entitlement is reserved.
    ///
    ///      When finalize runs with positions still open (escape hatch), each such position is
    ///      already inside the derived total at collateral + PnL: a solvent one later realizes to
    ///      exactly that figure, and a bankrupt one was counted below zero, so when it is settled
    ///      the residual funds its shortfall as far as it goes and that amount moves into the
    ///      principal ledger.
    /// @param pairVault The vault storage reference
    /// @param ts Terminal-settlement state (tallies in, frozen ratios out)
    /// @param params Termination parameters
    function executeTermination(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.TerminalSettlement storage ts,
        BazaarTypes.TerminationParams memory params
    ) external {
        if (params.settlementPrice == 0) {
            revert TerminationLib__TerminationPriceRequired();
        }

        // === Retire the estate ===
        // Its value enters the total owed below with a minus sign: a loss on the inventory is
        // the counterparties' gain, which they realize into buckets or claims; a gain is their
        // loss, already out of their buckets. Valued from the liquidatees' entry, price and
        // funding legs together, exactly as the coverage ratio and the ADL gate read it.
        int256 estateValue = RiskParamsLib.vaultPnl(pairVault, params.settlementPrice, params.currentFundingIndex);
        pairVault.pendingLiqSize = 0;
        pairVault.pendingLiqEntryNotional = 0;
        pairVault.pendingLiqBankruptcyNotional = 0;
        pairVault.pendingLiqEntryFundingIndex = 0;
        // The seizure earmarked against the retired inventory is released with it. The residual
        // written below is what the insurers own outright; an earmark that survived would keep
        // that much of it out of every redemption's basis for good.
        pairVault.pendingLiqSeized = 0;

        // === Total owed to traders ===
        // Σ collateral + Σ registered claims, from the ledger identity. The deficit is bad debt
        // realized before termination: winners' buckets were credited in full while the ledger
        // was credited only what insurance could fund, so it is part of what is owed. Clamped at
        // zero: only unsettled bankrupt positions can drive the derivation negative.
        uint256 owed;
        {
            int256 owedSigned = SafeCast.toInt256(pairVault.totalCollateralDeposited)
                + SafeCast.toInt256(pairVault.deficit) + SafeCast.toInt256(ts.terminalBadDebt) - estateValue;
            owed = owedSigned > 0 ? uint256(owedSigned) : 0;
        }
        pairVault.deficit = 0;
        uint256 claims = ts.totalProfitClaims;
        uint256 principal = owed > claims ? owed - claims : 0;

        // === Distributable pot: actual cash, net of the fee escrow ===
        uint256 pot = uint256(
            BazaarMathLib.convertExponent(
                int256(_netOfEscrow(_getUsdcBalance(params.usdc), params.claimableFeesTotal)),
                BazaarTypes.USDC_EXPONENT,
                BazaarTypes.BAZAAR_EXPONENT
            )
        );

        // === Freeze the ratios: principal first, profits from what remains ===
        uint256 principalRatioBp;
        uint256 profitRatioBp;
        uint256 reserved; // cash reserved for trader withdrawals
        if (pot >= principal) {
            principalRatioBp = BazaarTypes.BP_SCALE;
            uint256 profitPot = pot - principal;
            profitRatioBp = claims == 0 || profitPot >= claims
                ? BazaarTypes.BP_SCALE
                : Math.mulDiv(profitPot, BazaarTypes.BP_SCALE, claims);
            reserved = principal + Math.mulDiv(claims, profitRatioBp, BazaarTypes.BP_SCALE);
        } else {
            // Cash cannot cover principal: only a books-vs-balance gap gets here. Everything
            // traders can draw is the pot, shared pro-rata on collateral; profits pay nothing.
            principalRatioBp = Math.mulDiv(pot, BazaarTypes.BP_SCALE, principal);
            profitRatioBp = 0;
            reserved = pot;
        }
        ts.principalRatioBp = principalRatioBp;
        ts.profitRatioBp = profitRatioBp;

        // The ledgers take their terminal meaning: D is the principal still to be withdrawn
        // (claims are credited into it as they are paid), I is the insurers' residual.
        pairVault.totalCollateralDeposited = principal;
        pairVault.insuranceFundBalance = pot - reserved;

        emit PairTerminated(
            params.pairId,
            params.settlementPrice,
            owed,
            claims,
            ts.terminalBadDebt,
            estateValue,
            pot,
            principalRatioBp,
            profitRatioBp,
            pairVault.insuranceFundBalance,
            params.sweepComplete,
            block.timestamp
        );
    }

    /// @dev Cash actually distributable at termination: the balance less the fee escrow, in
    ///      USDC precision. Floored — an escrow larger than the balance means there is nothing
    ///      to distribute, and the shortfall surfaces through the ratios the caller derives.
    function _netOfEscrow(uint256 balanceUsdc, uint256 claimableFeesBazaar) internal pure returns (uint256) {
        uint256 escrowUsdc = uint256(
            BazaarMathLib.convertExponent(
                int256(claimableFeesBazaar), BazaarTypes.BAZAAR_EXPONENT, BazaarTypes.USDC_EXPONENT
            )
        );
        return balanceUsdc > escrowUsdc ? balanceUsdc - escrowUsdc : 0;
    }

    /// @notice Gets the USDC balance of the current contract (BazaarPair via DELEGATECALL)
    function _getUsdcBalance(address usdc) internal view returns (uint256) {
        (bool ok, bytes memory data) =
            usdc.staticcall(
                abi.encodeWithSelector(0x70a08231, address(this)) // balanceOf(address)
            );
        if (!ok || data.length < 32) revert TerminationLib__BalanceOfFailed();
        return abi.decode(data, (uint256));
    }
}
