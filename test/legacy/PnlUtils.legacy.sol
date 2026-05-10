// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * LEGACY (PLAINTEXT PnL UTILS)
 * ---------------------------
 * Tests `src/libraries/PnlUtils.sol` (plaintext helpers).
 *
 * ShadeSpot's current perps path computes PnL with CoFHE encrypted arithmetic in
 * `PositionManager`, not this library.
 *
 * Kept for reference only; not executed by default (not named `*.t.sol`).
 */

import "forge-std/Test.sol";
import "../../src/libraries/PnlUtils.sol";

contract PnlUtilsLegacyTest is Test {
    function calculatePnL(PnLUtils.Position memory pos, uint256 price) public pure returns (int256) {
        return PnLUtils.calculatePnL(pos, price);
    }

    function isProfit(PnLUtils.Position memory pos, uint256 price) public pure returns (bool) {
        return PnLUtils.isProfit(pos, price);
    }

    function getLoss(PnLUtils.Position memory pos, uint256 price) public pure returns (uint256) {
        return PnLUtils.getLoss(pos, price);
    }

    function getProfit(PnLUtils.Position memory pos, uint256 price) public pure returns (uint256) {
        return PnLUtils.getProfit(pos, price);
    }

    function test_CalculatePnL_Long_Profit() public {
        PnLUtils.Position memory pos = PnLUtils.Position({
            size: 1000 * 1e18,
            collateral: 100 * 1e18,
            entryPrice: 2000 * 1e18,
            isLong: true
        });

        int256 pnl = calculatePnL(pos, 2200 * 1e18);
        assertEq(pnl, 100 * 1e18);
        assertTrue(isProfit(pos, 2200 * 1e18));
        assertEq(getLoss(pos, 2200 * 1e18), 0);
        assertEq(getProfit(pos, 2200 * 1e18), 100 * 1e18);
    }

    function test_CalculatePnL_Long_Loss() public {
        PnLUtils.Position memory pos = PnLUtils.Position({
            size: 1000 * 1e18,
            collateral: 100 * 1e18,
            entryPrice: 2000 * 1e18,
            isLong: true
        });

        int256 pnl = calculatePnL(pos, 1800 * 1e18);
        assertEq(pnl, -100 * 1e18);
        assertFalse(isProfit(pos, 1800 * 1e18));
        assertEq(getLoss(pos, 1800 * 1e18), 100 * 1e18);
        assertEq(getProfit(pos, 1800 * 1e18), 0);
    }

    function test_CalculatePnL_Short_Profit() public {
        PnLUtils.Position memory pos = PnLUtils.Position({
            size: 1000 * 1e18,
            collateral: 100 * 1e18,
            entryPrice: 2000 * 1e18,
            isLong: false
        });

        int256 pnl = calculatePnL(pos, 1800 * 1e18);
        assertEq(pnl, 100 * 1e18);
        assertTrue(isProfit(pos, 1800 * 1e18));
        assertEq(getLoss(pos, 1800 * 1e18), 0);
    }

    function test_ZeroEntryPrice() public {
        PnLUtils.Position memory pos = PnLUtils.Position({
            size: 1000 * 1e18,
            collateral: 100 * 1e18,
            entryPrice: 0,
            isLong: true
        });

        assertEq(calculatePnL(pos, 2000 * 1e18), 0);
    }
}

