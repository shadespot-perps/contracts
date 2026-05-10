// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * LEGACY (PLAINTEXT FUNDING)
 * -------------------------
 * This file targets `src/core/FundingRateManager.sol` (plaintext funding).
 *
 * ShadeSpot's current protocol uses `src/core/FHEFundingRateManager.sol`.
 *
 * This is kept for reference/regression on the plaintext module only.
 * It is not executed by default because it is not named `*.t.sol`.
 */

import "forge-std/Test.sol";
import "../../src/core/FundingRateManager.sol";

contract FundingRateManagerTest is Test {
    FundingRateManager frm;

    address pm       = address(0x10);
    address router   = address(0x20);
    address token    = address(0x30);

    function setUp() public {
        frm = new FundingRateManager();
        frm.setPositionManager(pm);
        frm.setRouter(router);
    }

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

    function test_UpdateFunding_LongDominant() public {
        vm.prank(pm);
        frm.increaseOpenInterest(token, 7000 * 1e18, true);
        vm.prank(pm);
        frm.increaseOpenInterest(token, 3000 * 1e18, false);

        skip(1 hours + 1);
        frm.updateFunding(token);

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

        skip(30 minutes);
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

