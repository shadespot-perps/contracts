// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/libraries/PnlUtils.sol";

contract PnlUtilsFuzzTest is Test {

    // Wrapper to expose internal methods
    function calculatePnL(PnLUtils.Position memory pos, uint256 price) public pure returns (int256) {
        return PnLUtils.calculatePnL(pos, price);
    }

    function testFuzz_CalculatePnL(
        uint256 size,
        uint256 entryPrice,
        uint256 currentPrice,
        bool isLong
    ) public {
        // Bound inputs to avoid crazy overflows that unrealistic for this scale anyway
        vm.assume(entryPrice > 0 && entryPrice < 1e30);
        vm.assume(currentPrice > 0 && currentPrice < 1e30);
        vm.assume(size > 0 && size < 1e30);

        PnLUtils.Position memory pos = PnLUtils.Position({
            size: size,
            collateral: 0, // unused in PnL calc
            entryPrice: entryPrice,
            isLong: isLong
        });

        int256 pnl = calculatePnL(pos, currentPrice);

        // Properties (considering integer division truncation)
        if (isLong) {
            if (currentPrice > entryPrice) {
                assertTrue(pnl >= 0);
            } else if (currentPrice < entryPrice) {
                assertTrue(pnl <= 0);
            } else {
                assertEq(pnl, 0);
            }
        } else {
            if (currentPrice < entryPrice) {
                assertTrue(pnl >= 0);
            } else if (currentPrice > entryPrice) {
                assertTrue(pnl <= 0);
            } else {
                assertEq(pnl, 0);
            }
        }
    }
}
