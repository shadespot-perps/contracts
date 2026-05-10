// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * LEGACY FUZZ (PLAINTEXT FUNDING)
 * ------------------------------
 * Targets `src/core/FundingRateManager.sol` (plaintext).
 *
 * Note: this fuzz is known to be brittle with edge counterexamples as the
 * plaintext module evolves. Kept for reference only; not executed by default.
 */

import "forge-std/Test.sol";
import "../../src/core/FundingRateManager.sol";

contract FundingRateManagerFuzzLegacy is Test {
    FundingRateManager frm;
    address router = address(0x10);
    address pm = address(0x20);
    address token = address(0x30);

    function setUp() public {
        frm = new FundingRateManager();
        frm.setRouter(router);
        frm.setPositionManager(pm);
    }

    function testFuzz_FundingRateCalculationLimits(uint256 longOI, uint256 shortOI) public {
        vm.assume(longOI < 1e30);
        vm.assume(shortOI < 1e30);
        vm.assume(longOI > 0 || shortOI > 0);

        vm.warp(1 hours + 1);

        vm.startPrank(pm);
        if (longOI > 0) frm.increaseOpenInterest(token, longOI, true);
        if (shortOI > 0) frm.increaseOpenInterest(token, shortOI, false);
        vm.stopPrank();

        vm.prank(router);
        frm.updateFunding(token);

        int256 rate = frm.getFundingRate(token);
        uint256 absRate = rate >= 0 ? uint256(rate) : uint256(-rate);
        assertTrue(absRate <= 1e12);

        if (longOI > shortOI) {
            assertTrue(rate > 0);
        } else if (shortOI > longOI) {
            assertTrue(rate < 0);
        } else {
            assertEq(rate, 0);
        }
    }
}

