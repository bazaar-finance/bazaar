// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {BazaarTypes} from "../libraries/BazaarTypes.sol";

interface IBazaarPair {
    // ---- State getters used by BazaarPairTerminator ----
    function pairId() external view returns (bytes32);
    function baseFeedId() external view returns (bytes32);
    function oracle() external view returns (address);
    function isPairTerminated() external view returns (bool);
    function scheduledTerminationTs() external view returns (uint256);
    function settlementPriceFixedTs() external view returns (uint256);
    function auxState() external view returns (BazaarTypes.AuxState memory);

    // ---- Price helpers used by BazaarPairTerminator ----
    function lastPairPrice()
        external
        view
        returns (uint256 spotPrice, uint256 emaVarianceBp, uint256 updateTs, uint256 lowPrice, uint256 highPrice);

    // ---- Insurance share getters used by insurer-vote termination ----
    function totalInsuranceShares() external view returns (uint256);
    function insuranceShares(address user) external view returns (uint256);
    function getSharesAsOf(address user, uint64 atTs) external view returns (uint256);
    /// @notice Raw storage read, for pair state that has no getter (see BazaarPairTerminator's
    ///         PAIR_SLOT_SHARE_EPOCH).
    function extsload(bytes32 slot) external view returns (bytes32);

    // ---- Setters called by BazaarPairTerminator ----
    function setScheduledTermination(uint256 lastTradingTs, address proposer) external;
    /// @notice Stage 1 of termination: pins the settlement price and opens the settlement
    ///         window. Stage 2 (BazaarPair.finalizeTermination) is public and freezes the payout
    ///         ratios once every position is settled at this price, or once the escape hatch
    ///         has elapsed.
    function fixSettlementPrice(uint256 settlementPrice) external;

    /// @notice Credits already-transferred USDC into the insurance fund bookkeeping.
    /// @dev Called by BazaarPairTerminator (forfeited insurer-termination bonds) after it has
    ///      already `safeTransfer`'d the matching USDC to the pair, keeping the contract's USDC
    ///      balance and the insurance accounting in sync.
    function creditInsurance(uint256 amountBazaarPrecision) external;
}
