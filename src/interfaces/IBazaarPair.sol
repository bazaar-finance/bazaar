// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

interface IBazaarPair {
    function batchHashes(uint256 batchId) external view returns (bytes32);

    function orders(uint256 orderId)
        external
        view
        returns (
            address creator,
            address integrator,
            uint256 triggerPrice,
            uint256 limitPrice,
            uint256 maxSlippageBp,
            uint256 size,
            uint256 filledSize,
            uint8 orderType,
            bool isLong,
            bool isPostOnly,
            uint64 creationBlock,
            uint64 expiryBlock,
            uint64 canceledBlock,
            uint64 filledBlock
        );

    // ---- State getters used by BazaarPairTerminator ----
    function pairId() external view returns (bytes32);
    function baseFeedId() external view returns (bytes32);
    function oracle() external view returns (address);
    function isPairTerminatedEmergency() external view returns (bool);
    function isPairTerminatedNormal() external view returns (bool);
    function scheduledTerminationTs() external view returns (uint256);
    function settlementPriceFixedTs() external view returns (uint256);

    // ---- Price helpers used by BazaarPairTerminator ----
    function lastPairPrice()
        external
        view
        returns (uint256 spotPrice, uint256 emaVarianceBp, uint256 updateTs, uint256 lowPrice, uint256 highPrice);

    // ---- Insurance share getters used by insurer-vote termination ----
    function totalInsuranceShares() external view returns (uint256);
    function insuranceShares(address user) external view returns (uint256);
    function getSharesAsOf(address user, uint64 atTs) external view returns (uint256);

    // ---- Setters called by BazaarPairTerminator ----
    function setScheduledTermination(uint256 lastTradingTs, address proposer) external;
    /// @notice Stage 1 of normal termination: pins the settlement price and opens the terminal
    ///         sweep window. Stage 2 (BazaarPair.finalizeTermination) is public and settles the
    ///         book at this price once the window elapses.
    function fixSettlementPrice(uint256 settlementPrice) external;

    /// @notice Credits a forfeited insurer-termination bond into the insurance fund.
    /// @dev Called by BazaarPairTerminator after it has already `safeTransfer`'d the USDC
    ///      bond to this pair. Updates the bookkeeping so the contract's USDC balance
    ///      and the insurance fund accounting stay in sync.
    function creditInsuranceFromTerminator(uint256 amountBazaarPrecision) external;

    /// @notice Credits a stale-batch-challenge slash share into the insurance fund.
    /// @dev Called by BazaarSequencer after it has already `safeTransfer`'d the USDC share to this
    ///      pair. Restricted to the registered sequencer; keeps USDC balance and insurance
    ///      accounting in sync.
    function creditInsuranceFromSequencer(uint256 amountBazaarPrecision) external;
}
