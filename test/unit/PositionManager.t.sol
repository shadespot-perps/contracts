// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/PositionManager.sol";
import "../../src/core/Vault.sol";
import "../../src/core/FundingRateManager.sol";
import "../../src/oracle/PriceOracle.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract PositionManagerTest is Test {
    PositionManager pm;
    Vault vault;
    PriceOracle oracle;
    FundingRateManager fundingRateManager;
    ERC20Mock collateralToken;

    address owner = address(this);
    address router = address(0x10);
    address liquidationManager = address(0x20);
    address trader = address(0x30);
    address token;

    function setUp() public {
        collateralToken = new ERC20Mock();
        token = address(collateralToken);

        oracle = new PriceOracle();
        fundingRateManager = new FundingRateManager();
        vault = new Vault(token, owner);
        
        pm = new PositionManager(address(vault), address(oracle), address(fundingRateManager));
        
        // Wires
        pm.setRouter(router);
        pm.setLiquidationManager(liquidationManager);
        vault.setPositionManager(address(pm));
        vault.setRouter(router);
        fundingRateManager.setPositionManager(address(pm));
        
        // Set initial price
        oracle.setPrice(token, 2000 * 1e18); // $2000 per token
        
        // Provide vault liquidity
        vm.prank(router);
        vault.deposit(100_000 * 1e18);
        collateralToken.mint(address(vault), 100_000 * 1e18);
    }

    function test_OpenPosition_HappyPath() public {
        uint256 collateral = 1000 * 1e18;
        uint256 leverage = 5;
        bool isLong = true;

        vm.prank(router);
        pm.openPosition(trader, token, collateral, leverage, isLong);

        bytes32 key = pm.getPositionKey(trader, token, isLong);
        PositionManager.Position memory pos = pm.getPosition(key);

        assertEq(pos.owner, trader);
        assertEq(pos.size, 5000 * 1e18);
        assertEq(pos.collateral, collateral);
        assertEq(pos.entryPrice, 2000 * 1e18);
        assertEq(pos.isLong, isLong);
        
        assertEq(vault.totalReserved(), 5000 * 1e18);
        (uint256 longOI, ) = fundingRateManager.getOpenInterest(token);
        assertEq(longOI, 5000 * 1e18);
    }

    function test_OpenPosition_Revert_MaxLeverage() public {
        vm.prank(router);
        vm.expectRevert("exceeds max leverage");
        pm.openPosition(trader, token, 1000, 11, true); // 11x leverage
    }

    function test_ClosePosition_Profit() public {
        uint256 collateral = 1000 * 1e18;
        uint256 leverage = 5;
        bool isLong = true;

        vm.startPrank(router);
        pm.openPosition(trader, token, collateral, leverage, isLong);
        vm.stopPrank();
        
        // Price goes up 10% to 2200
        oracle.setPrice(token, 2200 * 1e18);
        
        vm.startPrank(router);
        pm.closePosition(trader, token, isLong);
        vm.stopPrank();

        // Size = 5000. Profit = (2200 - 2000) * 5000 / 2000 = 500
        // Expected trader payout = 1000 + 500 = 1500
        assertEq(collateralToken.balanceOf(trader), 1500 * 1e18);
        
        bytes32 key = pm.getPositionKey(trader, token, isLong);
        PositionManager.Position memory pos = pm.getPosition(key);
        assertEq(pos.size, 0); // Position deleted
        assertEq(vault.totalReserved(), 0);
        (uint256 longOI_close, ) = fundingRateManager.getOpenInterest(token);
        assertEq(longOI_close, 0);
    }

    function test_CalculatePnL_Long() public {
        PositionManager.Position memory pos;
        pos.size = 5000 * 1e18;
        pos.entryPrice = 2000 * 1e18;
        pos.isLong = true;

        // Up 10%
        assertEq(pm.calculatePnL(pos, 2200 * 1e18), 500 * 1e18); // Profit 500
        // Down 10%
        assertEq(pm.calculatePnL(pos, 1800 * 1e18), -500 * 1e18); // Loss 500
    }

    function test_CalculatePnL_Short() public {
        PositionManager.Position memory pos;
        pos.size = 5000 * 1e18;
        pos.entryPrice = 2000 * 1e18;
        pos.isLong = false;

        // Down 10%
        assertEq(pm.calculatePnL(pos, 1800 * 1e18), 500 * 1e18); // Profit 500
        // Up 10%
        assertEq(pm.calculatePnL(pos, 2200 * 1e18), -500 * 1e18); // Loss 500
    }
}
