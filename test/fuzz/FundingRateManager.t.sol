// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/FundingRateManager.sol";

contract FundingRateManagerFuzzTest is Test {
    FundingRateManager frm;
    
    address owner = address(this);
    address router = address(0x10);
    address pm = address(0x20);
    address token = address(0x30);

    function setUp() public {
        frm = new FundingRateManager();
        frm.setRouter(router);
        frm.setPositionManager(pm);
    }

    function testFuzz_FundingRateCalculationLimits(
        uint256 longOI,
        uint256 shortOI
    ) public {
        // Assume non-zero limits and stay within reasonable boundaries (e.g., $1 trillion at 18 decimals)
        vm.assume(longOI < 1e30);
        vm.assume(shortOI < 1e30);
        vm.assume(longOI > 0 || shortOI > 0);

        // Warp time so interval ticks
        vm.warp(1 hours + 1);

        vm.startPrank(pm);
        if (longOI > 0) frm.increaseOpenInterest(token, longOI, true);
        if (shortOI > 0) frm.increaseOpenInterest(token, shortOI, false);
        vm.stopPrank();

        vm.prank(router);
        frm.updateFunding(token);

        int256 rate = frm.getFundingRate(token);
        
        // Property: Absolute funding rate cannot exceed FUNDING_RATE_PRECISION (1 * 1e12, or 100% per hour)
        uint256 absRate = rate >= 0 ? uint256(rate) : uint256(-rate);
        assertTrue(absRate <= 1000000000000); // 1e12

        // Property: If long > short, rate is positive
        if (longOI > shortOI) {
            assertTrue(rate > 0);
        } else if (shortOI > longOI) {
            assertTrue(rate < 0);
        } else {
            assertEq(rate, 0);
        }
    }
}
