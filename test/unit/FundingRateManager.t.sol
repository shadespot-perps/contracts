// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/FundingRateManager.sol";

contract FundingRateManagerTest is Test {
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

    function test_IncreaseDecreaseOpenInterest() public {
        vm.startPrank(pm);
        frm.increaseOpenInterest(token, 1000, true);
        frm.increaseOpenInterest(token, 500, false);
        
        (uint256 longOI, uint256 shortOI) = frm.getOpenInterest(token);
        assertEq(longOI, 1000);
        assertEq(shortOI, 500);

        frm.decreaseOpenInterest(token, 200, true);
        (longOI, shortOI) = frm.getOpenInterest(token);
        assertEq(longOI, 800);
        assertEq(shortOI, 500);
        
        vm.stopPrank();
    }

    function test_UpdateFunding_LongsDominant() public {
        // Warp to make sure we are past FUNDING_INTERVAL since genesis (genesis = 0)
        vm.warp(1 hours + 1);

        vm.startPrank(pm);
        frm.increaseOpenInterest(token, 3000, true);
        frm.increaseOpenInterest(token, 1000, false);
        vm.stopPrank();
        
        vm.prank(router);
        frm.updateFunding(token);

        // Imbalance = 2000. Total = 4000. Rate = 2000 * 1e12 / 4000 = 0.5 * 1e12 = 5e11
        assertEq(frm.getFundingRate(token), 500_000_000_000);
    }

    function test_UpdateFunding_ShortsDominant() public {
        vm.warp(1 hours + 1);

        vm.startPrank(pm);
        frm.increaseOpenInterest(token, 1000, true);
        frm.increaseOpenInterest(token, 3000, false);
        vm.stopPrank();
        
        vm.prank(router);
        frm.updateFunding(token);

        // Imbalance = 2000. Total = 4000. Rate = -2000 * 1e12 / 4000 = -5e11
        assertEq(frm.getFundingRate(token), -500_000_000_000);
    }

    function test_UpdateFunding_SkipsBeforeInterval() public {
        vm.warp(1 hours + 1);

        vm.prank(pm);
        frm.increaseOpenInterest(token, 3000, true);
        
        vm.prank(router);
        frm.updateFunding(token); // Ticks

        int256 rate1 = frm.getFundingRate(token);
        assertEq(rate1, 1e12); // Longs 100% dominant

        vm.warp(block.timestamp + 30 minutes);
        vm.prank(router);
        frm.updateFunding(token); // Should skip

        assertEq(frm.getFundingRate(token), rate1);
    }
}
