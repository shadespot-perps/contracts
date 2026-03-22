// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../../src/core/Vault.sol";
import "../../src/core/PositionManager.sol";
import "../../src/core/LiquidationManager.sol";
import "../../src/core/FundingRateManager.sol";
import "../../src/trading/Router.sol";
import "../../src/trading/OrderManager.sol";
import "../../src/oracle/PriceOracle.sol";

import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract UserFlowTest is Test {
    ERC20Mock collateralToken;
    PriceOracle oracle;
    FundingRateManager fundingManager;
    Vault vault;
    PositionManager positionManager;
    OrderManager orderManager;
    Router router;
    LiquidationManager liquidationManager;

    address owner = address(this);
    address lp = address(0x1);
    address trader = address(0x2);

    function setUp() public {
        vm.label(lp, "LiquidityProvider");
        vm.label(trader, "Trader");

        // 1. Deploy mock collateral token (e.g., USDC)
        collateralToken = new ERC20Mock();
        
        // 2. Deploy PriceOracle
        oracle = new PriceOracle();
        
        // 3. Deploy FundingRateManager
        fundingManager = new FundingRateManager();
        
        // 4. Deploy Vault
        vault = new Vault(address(collateralToken), owner);
        
        // 5. Deploy PositionManager
        positionManager = new PositionManager(address(vault), address(oracle), address(fundingManager));
        
        // 6. Deploy OrderManager
        orderManager = new OrderManager(address(oracle), address(fundingManager), owner);
        
        // 7. Deploy Router
        router = new Router(
            address(positionManager),
            address(vault),
            address(orderManager),
            address(fundingManager),
            address(collateralToken)
        );
        
        // 8. Deploy LiquidationManager
        liquidationManager = new LiquidationManager(
            address(positionManager),
            address(oracle),
            address(vault),
            address(fundingManager)
        );

        // Wiring privileges
        vault.setPositionManager(address(positionManager));
        vault.setRouter(address(router));
        positionManager.setRouter(address(router));
        positionManager.setLiquidationManager(address(liquidationManager));
        fundingManager.setRouter(address(router));
        fundingManager.setPositionManager(address(positionManager));
        orderManager.setRouter(address(router));

        // Setup mock prices
        oracle.setPrice(address(collateralToken), 1000 * 1e18); // Example price for WETH index: 1 WETH = $1000

        // Mint collateral to users
        collateralToken.mint(lp, 100_000 * 1e18); // 100k
        collateralToken.mint(trader, 10_000 * 1e18); // 10k
    }

    function test_SmokeUserFlow() public {
        uint256 lpAmount = 50_000 * 1e18;
        uint256 traderMargin = 1_000 * 1e18;
        uint256 leverage = 5;

        // LP adds liquidity
        vm.startPrank(lp);
        collateralToken.approve(address(router), lpAmount);
        router.addLiquidity(lpAmount);
        vm.stopPrank();

        assertEq(vault.totalLiquidity(), lpAmount, "totalLiquidity mismatch");

        // Trader opens a Long position
        vm.startPrank(trader);
        collateralToken.approve(address(router), traderMargin);
        router.openPosition(
            address(collateralToken), // Token being traded (serving as index here)
            traderMargin,             // 1000 margin
            leverage,                 // 5x
            true                      // long
        );
        vm.stopPrank();

        bytes32 posKey = positionManager.getPositionKey(trader, address(collateralToken), true);
        PositionManager.Position memory pos = positionManager.getPosition(posKey);
        
        assertEq(pos.size, traderMargin * leverage, "position size mismatch");
        assertEq(pos.collateral, traderMargin, "position collateral mismatch");
        assertEq(pos.entryPrice, 1000 * 1e18, "entry price mismatch");

        // Simulate price go up: WETH goes from 1000 to 1100 (+10%)
        oracle.setPrice(address(collateralToken), 1100 * 1e18);

        // Trader closes position
        uint256 balanceBefore = collateralToken.balanceOf(trader);
        
        vm.startPrank(trader);
        router.closePosition(address(collateralToken), true);
        vm.stopPrank();

        uint256 balanceAfter = collateralToken.balanceOf(trader);
        
        // PnL analysis:
        // Position size: 5000 notional
        // Price increased by 10%.
        // Profit = (1100 - 1000) * 5000 / 1000 = 500
        // Trader gets back Margin (1000) + Profit (500) = 1500. 
        // Note: Funding might be zero because shorts=0 and longs=5000. Actually if longs > shorts, longs pay shorts/vault.
        
        console.log("Trader balance before:", balanceBefore / 1e18);
        console.log("Trader balance after:", balanceAfter / 1e18);

        assertTrue(balanceAfter > balanceBefore, "Trader should have made a profit");
    }
}
