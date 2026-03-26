// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IVault
 * @notice Common interface implemented by both Vault (USDC pool) and FHEVault (FHE token pool).
 *         PositionManager depends only on this interface so it can serve either pool.
 */
interface IVault {
    function reserveLiquidity(uint256 amount) external;
    function releaseLiquidity(uint256 amount) external;
    function payTrader(address user, uint256 profit, uint256 returnedCollateral) external;
    function receiveLoss(uint256 amount) external;
    function refundCollateral(address user, uint256 amount) external;
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
}
