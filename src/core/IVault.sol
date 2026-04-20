// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IVault
 * @notice Common vault interface used by PositionManager.
 */
interface IVault {
    /// @notice Reserves liquidity for a new position.
    function reserveLiquidity(address trader) external;
    function releaseLiquidity(uint256 amount) external;
    function payTrader(address user, uint256 profit, uint256 returnedCollateral) external;
    function receiveLoss(uint256 amount) external;
    function refundCollateral(address user, uint256 amount) external;
    function deposit(address lp, uint256 amount) external;
    function withdraw(address lp, uint256 shares) external returns (uint256 amount);
}
