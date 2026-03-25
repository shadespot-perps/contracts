// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/FundingRateManager.sol";

/**
 * FundingRateManager is currently plaintext (reverted by formatter).
 * Tests exercise OI accounting and rate computation directly without FHE.
 */
contract FundingRateManagerTest is Test {
    FundingRateManager frm;

    address owner    = address(this);
    address pm       = address(0x10);
    address router   = address(0x20);
    address token    = address(0x30);

    function setUp() public {
        frm = new FundingRateManager();
        frm.setPositionManager(pm);
        frm.setRouter(router);
    }

    // ------------------------------------------------------------------
    // OPEN INTEREST
    // ------------------------------------------------------------------

    function test_IncreaseOpenInterest() public {
        vm.prank(pm);
        frm.increaseOpenInterest(token, 5000 * 1e18, true);

        (uint256 longOI, uint256 shortOI) = frm.getOpenInterest(token);
        assertEq(longOI,  5000 * 1e18);
        assertEq(shortOI, 0);
    }

    function test_DecreaseOpenInterest() public {
        vm.prank(pm);
        frm.increaseOpenInterest(token, 5000 * 1e18, true);

        vm.prank(pm);
        frm.decreaseOpenInterest(token, 2000 * 1e18, true);

        (uint256 longOI,) = frm.getOpenInterest(token);
        assertEq(longOI, 3000 * 1e18);
    }

    function test_OI_Revert_OnlyPositionManager() public {
        vm.expectRevert("only position manager");
        frm.increaseOpenInterest(token, 1000, true);
    }

    // ------------------------------------------------------------------
    // FUNDING RATE
    // ------------------------------------------------------------------

    function test_UpdateFunding_LongDominant() public {
        vm.prank(pm);
        frm.increaseOpenInterest(token, 7000 * 1e18, true);
        vm.prank(pm);
        frm.increaseOpenInterest(token, 3000 * 1e18, false);

        // Advance past the 1-hour interval
        skip(1 hours + 1);
        frm.updateFunding(token);

        // imbalance = 4000, total = 10000 → rate = 4000/10000 * 1e12 = 4e11 (positive, longs pay)
        int256 rate = frm.getFundingRate(token);
        assertGt(rate, 0);
        assertEq(rate, int256((4000 * frm.FUNDING_RATE_PRECISION()) / 10000));
    }

    function test_UpdateFunding_ShortDominant() public {
        vm.prank(pm);
        frm.increaseOpenInterest(token, 3000 * 1e18, true);
        vm.prank(pm);
        frm.increaseOpenInterest(token, 7000 * 1e18, false);

        skip(1 hours + 1);
        frm.updateFunding(token);

        int256 rate = frm.getFundingRate(token);
        assertLt(rate, 0);
        assertEq(rate, -int256((4000 * frm.FUNDING_RATE_PRECISION()) / 10000));
    }

    function test_UpdateFunding_NoOI_NoChange() public {
        skip(1 hours + 1);
        frm.updateFunding(token);

        assertEq(frm.getFundingRate(token), 0);
    }

    function test_UpdateFunding_TooEarly_NoChange() public {
        vm.prank(pm);
        frm.increaseOpenInterest(token, 5000 * 1e18, true);

        skip(30 minutes); // < 1 hour
        frm.updateFunding(token);

        assertEq(frm.getFundingRate(token), 0);
    }

    function test_UpdateFunding_CumulatesAcrossIntervals() public {
        vm.prank(pm);
        frm.increaseOpenInterest(token, 6000 * 1e18, true);
        vm.prank(pm);
        frm.increaseOpenInterest(token, 4000 * 1e18, false);

        int256 expectedRate = int256((2000 * frm.FUNDING_RATE_PRECISION()) / 10000);

        skip(1 hours + 1);
        frm.updateFunding(token);

        skip(1 hours + 1);
        frm.updateFunding(token);

        assertEq(frm.getFundingRate(token), 2 * expectedRate);
    }
}
