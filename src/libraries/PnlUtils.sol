// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library PnLUtils {

    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 entryPrice;
        bool isLong;
    }

    /**
     * @notice Calculate PnL of a position
     * @param position Position data
     * @param currentPrice Current oracle price
     */
    function calculatePnL(
        Position memory position,
        uint256 currentPrice
    ) internal pure returns (int256) {

        if (position.entryPrice == 0) {
            return 0;
        }

        int256 priceDiff;

        if (position.isLong) {
            priceDiff = int256(currentPrice) - int256(position.entryPrice);
        } else {
            priceDiff = int256(position.entryPrice) - int256(currentPrice);
        }

        return (priceDiff * int256(position.size)) / int256(position.entryPrice);
    }

    /**
     * @notice Check if position is profitable
     */
    function isProfit(
        Position memory position,
        uint256 currentPrice
    ) internal pure returns (bool) {

        return calculatePnL(position, currentPrice) > 0;
    }

    /**
     * @notice Return absolute loss
     */
    function getLoss(
        Position memory position,
        uint256 currentPrice
    ) internal pure returns (uint256) {

        int256 pnl = calculatePnL(position, currentPrice);

        if (pnl >= 0) {
            return 0;
        }

        return uint256(-pnl);
    }

    /**
     * @notice Return absolute profit
     */
    function getProfit(
        Position memory position,
        uint256 currentPrice
    ) internal pure returns (uint256) {

        int256 pnl = calculatePnL(position, currentPrice);

        if (pnl <= 0) {
            return 0;
        }

        return uint256(pnl);
    }
}