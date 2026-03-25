// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/trading/OrderManager.sol";
import "../../src/oracle/PriceOracle.sol";
import "../../src/core/FundingRateManager.sol";
import "../mocks/MockTaskManager.sol";

contract OrderManagerTest is Test {
    address constant TASK_MANAGER = 0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9;

    OrderManager om;
    PriceOracle oracle;
    FundingRateManager frm;

    address owner  = address(this);
    address router = address(0x10);
    address trader = address(0x20);
    address token  = address(0x30);

    function setUp() public {
        // triggerPrice is stored as euint128 — mock needed for FHE.asEuint128().
        vm.etch(TASK_MANAGER, address(new MockTaskManager()).code);

        oracle = new PriceOracle();
        frm    = new FundingRateManager();
        om     = new OrderManager(address(oracle), address(frm), owner);
        om.setRouter(router);
    }

    // ------------------------------------------------------------------
    // CREATE ORDER
    // ------------------------------------------------------------------

    function test_CreateOrder() public {
        vm.prank(router);
        om.createOrder(trader, token, 1000 * 1e18, 5, 2000 * 1e18, true);

        assertEq(om.nextOrderId(), 1);

        // Use getOrderMeta — avoids ABI issues with euint128 in struct getter.
        (address oTrader, address oToken, uint256 oCollateral, uint256 oLeverage, bool isLong, bool isActive)
            = om.getOrderMeta(0);

        assertEq(oTrader,    trader);
        assertEq(oToken,     token);
        assertEq(oCollateral, 1000 * 1e18);
        assertEq(oLeverage,   5);
        assertTrue(isLong);
        assertTrue(isActive);
    }

    // ------------------------------------------------------------------
    // CANCEL ORDER
    // ------------------------------------------------------------------

    function test_CancelOrder() public {
        vm.prank(router);
        om.createOrder(trader, token, 1000 * 1e18, 5, 2000 * 1e18, true);

        vm.prank(router);
        om.cancelOrder(0, trader);

        (,,,, , bool isActive) = om.getOrderMeta(0);
        assertFalse(isActive);
    }

    function test_CancelOrder_Revert_NotOwner() public {
        vm.prank(router);
        om.createOrder(trader, token, 1000 * 1e18, 5, 2000 * 1e18, true);

        vm.prank(router);
        vm.expectRevert("not owner");
        om.cancelOrder(0, address(0x99));
    }

    // ------------------------------------------------------------------
    // EXECUTE ORDER
    // ------------------------------------------------------------------

    function test_ExecuteOrder_Long() public {
        vm.prank(router);
        // Long: triggers when price <= 2000
        om.createOrder(trader, token, 1000 * 1e18, 5, 2000 * 1e18, true);

        oracle.setPrice(token, 1900 * 1e18); // valid — below trigger

        vm.prank(router);
        om.executeOrder(0);

        (,,,, , bool isActive) = om.getOrderMeta(0);
        assertFalse(isActive);
    }

    function test_ExecuteOrder_Long_Revert_PriceNotReached() public {
        vm.prank(router);
        om.createOrder(trader, token, 1000 * 1e18, 5, 2000 * 1e18, true);

        oracle.setPrice(token, 2100 * 1e18); // above trigger — should not execute

        vm.prank(router);
        vm.expectRevert("price not reached");
        om.executeOrder(0);
    }

    function test_ExecuteOrder_Short() public {
        vm.prank(router);
        // Short: triggers when price >= 2000
        om.createOrder(trader, token, 1000 * 1e18, 5, 2000 * 1e18, false);

        oracle.setPrice(token, 2100 * 1e18); // valid — above trigger

        vm.prank(router);
        om.executeOrder(0);

        (,,,, , bool isActive) = om.getOrderMeta(0);
        assertFalse(isActive);
    }
}
