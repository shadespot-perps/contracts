// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/trading/OrderManager.sol";
import "../../src/oracle/PriceOracle.sol";
import "../../src/core/FundingRateManager.sol";

contract OrderManagerTest is Test {
    OrderManager om;
    PriceOracle oracle;
    FundingRateManager frm;
    
    address owner = address(this);
    address router = address(0x10);
    address trader = address(0x20);
    address token = address(0x30);

    function setUp() public {
        oracle = new PriceOracle();
        frm = new FundingRateManager();
        om = new OrderManager(address(oracle), address(frm), owner);
        om.setRouter(router);
    }

    function test_CreateOrder() public {
        vm.prank(router);
        om.createOrder(trader, token, 1000 * 1e18, 5, 2000 * 1e18, true);
        
        // orderId starts at 0
        (address oTrader, address oToken, uint256 oCollateral, uint256 oLeverage, uint256 oTp, bool isLong, bool isActive) = om.orders(0);
        
        assertEq(oTrader, trader);
        assertEq(oToken, token);
        assertEq(oCollateral, 1000 * 1e18);
        assertEq(oLeverage, 5);
        assertEq(oTp, 2000 * 1e18);
        assertTrue(isLong);
        assertTrue(isActive);
        
        assertEq(om.nextOrderId(), 1);
    }

    function test_CancelOrder() public {
        vm.prank(router);
        om.createOrder(trader, token, 1000 * 1e18, 5, 2000 * 1e18, true);
        
        vm.prank(router);
        om.cancelOrder(0, trader); // Router passes the correct trader caller
        
        (,,,,,, bool isActive) = om.orders(0);
        assertFalse(isActive);
    }

    function test_CancelOrder_Revert_NotOwner() public {
        vm.prank(router);
        om.createOrder(trader, token, 1000 * 1e18, 5, 2000 * 1e18, true);
        
        vm.prank(router);
        vm.expectRevert("not owner");
        om.cancelOrder(0, address(0x99));
    }

    function test_ExecuteOrder_Long() public {
        vm.prank(router);
        // Long order trigger = 2000. Price must be <= 2000
        om.createOrder(trader, token, 1000 * 1e18, 5, 2000 * 1e18, true);
        
        oracle.setPrice(token, 1900 * 1e18); // Valid price
        
        vm.prank(router);
        om.executeOrder(0);
        
        (,,,,,, bool isActive) = om.orders(0);
        assertFalse(isActive);
    }

    function test_ExecuteOrder_Long_Revert_PriceNotReached() public {
        vm.prank(router);
        om.createOrder(trader, token, 1000 * 1e18, 5, 2000 * 1e18, true);
        
        oracle.setPrice(token, 2100 * 1e18); // Not <= 2000
        
        vm.prank(router);
        vm.expectRevert("price not reached");
        om.executeOrder(0);
    }

    function test_ExecuteOrder_Short() public {
        vm.prank(router);
        // Short order trigger = 2000. Price must be >= 2000
        om.createOrder(trader, token, 1000 * 1e18, 5, 2000 * 1e18, false);
        
        oracle.setPrice(token, 2100 * 1e18); // Valid price
        
        vm.prank(router);
        om.executeOrder(0);
        
        (,,,,,, bool isActive) = om.orders(0);
        assertFalse(isActive);
    }
}
