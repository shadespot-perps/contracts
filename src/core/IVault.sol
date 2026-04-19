// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IVault
 * @notice Common interface implemented by both Vault (USDC pool) and FHEVault (FHE token pool).
 *         PositionManager depends only on this interface so it can serve either pool.
 *
Privacy note (ShadeSpot / FHEVault):
 *   reserveLiquidity securely consumes locally stored encrypted the
 *   pre-approved size from its own internal storage (set during the FHE decrypt-proof
 *   or trader-approval flow) so all volumes remain shielded on-chain on
 *   the PositionManager → Vault path.
 */
interface IVault {
    /// @notice Reserve liquidity for a new position.
    ///         legacy plaintext architecture (Vault): reads amount from `_pendingSize[trader]` set by Router.
    ///         FHEVault: reads amount from `_liqApprovedAmount[trader]` set by
    ///         `storeReserveLiquidityProof`.
    function reserveLiquidity(address trader) external;
    function releaseLiquidity(uint256 amount) external;
    function payTrader(address user, uint256 profit, uint256 returnedCollateral) external;
    function receiveLoss(uint256 amount) external;
    function refundCollateral(address user, uint256 amount) external;
    function deposit(address lp, uint256 amount) external;
    function withdraw(address lp, uint256 shares) external returns (uint256 amount);
}
