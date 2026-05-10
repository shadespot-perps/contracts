// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * LEGACY FUZZ (PLAINTEXT PnL UTILS)
 * --------------------------------
 * Targets `src/libraries/PnlUtils.sol` (plaintext).
 *
 * Kept for reference only; not executed by default (not named `*.t.sol`).
 */

import "forge-std/Test.sol";
import "../../src/libraries/PnlUtils.sol";

contract PnlUtilsFuzzLegacy is Test {
    function calculatePnL(PnLUtils.Position memory pos, uint256 price) public pure returns (int256) {
        return PnLUtils.calculatePnL(pos, price);
    }

    function testFuzz_CalculatePnL(uint256 size, uint256 entryPrice, uint256 currentPrice, bool isLong) public {
        vm.assume(entryPrice > 0 && entryPrice < 1e30);
        vm.assume(currentPrice > 0 && currentPrice < 1e30);
        vm.assume(size > 0 && size < 1e30);

        PnLUtils.Position memory pos = PnLUtils.Position({
            size: size,
            collateral: 0,
            entryPrice: entryPrice,
            isLong: isLong
        });

        int256 pnl = calculatePnL(pos, currentPrice);

        if (isLong) {
            if (currentPrice > entryPrice) assertTrue(pnl >= 0);
            else if (currentPrice < entryPrice) assertTrue(pnl <= 0);
            else assertEq(pnl, 0);
        } else {
            if (currentPrice < entryPrice) assertTrue(pnl >= 0);
            else if (currentPrice > entryPrice) assertTrue(pnl <= 0);
            else assertEq(pnl, 0);
        }
    }
}

