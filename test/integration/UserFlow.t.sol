// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "cofhe-contracts/FHE.sol";
import "../../src/core/PositionManager.sol";
import "../../src/core/LiquidationManager.sol";
import "../../src/core/FundingRateManager.sol";
import "../../src/core/Vault.sol";
import "../../src/trading/Router.sol";
import "../../src/trading/OrderManager.sol";
import "../../src/oracle/PriceOracle.sol";
import "../mocks/MockTaskManager.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract UserFlowTest is Test {
    address constant TASK_MANAGER = 0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9;

    PositionManager    positionManager;
    LiquidationManager liquidationManager;
    FundingRateManager fundingManager;
    Vault              vault;
    Router             router;
    OrderManager       orderManager;
    PriceOracle        oracle;
    ERC20Mock          collateralToken;
    ERC20Mock          ethMock;        // stand-in for ETH — only needs an address for the oracle

    address owner     = address(this);
    address trader    = address(0x100);
    address liquidator = address(0x200);
    address token;     // ETH index token address

    function setUp() public {
        vm.etch(TASK_MANAGER, address(new MockTaskManager()).code);

        collateralToken = new ERC20Mock();   // USDC collateral
        ethMock         = new ERC20Mock();   // ETH trade token (price feed only)
        token           = address(ethMock);

        oracle         = new PriceOracle();
        fundingManager = new FundingRateManager();
        vault          = new Vault(address(collateralToken), owner);
        positionManager = new PositionManager(address(vault), address(oracle), address(fundingManager));

        // LiquidationManager: positionManager + fundingManager only
        liquidationManager = new LiquidationManager(address(positionManager), address(fundingManager));

        orderManager = new OrderManager(address(oracle), address(fundingManager), owner);
        router       = new Router(
            address(positionManager),
            address(vault),
            address(orderManager),
            address(fundingManager),
            address(collateralToken),
            token                      // indexToken = ETH
        );

        positionManager.setRouter(address(router));
        positionManager.setLiquidationManager(address(liquidationManager));
        vault.setPositionManager(address(positionManager));
        vault.setRouter(address(router));
        fundingManager.setPositionManager(address(positionManager));
        fundingManager.setRouter(address(router));
        orderManager.setRouter(address(router));

        oracle.setPrice(token, 2000 * 1e18);

        // LP adds 100 000 tokens to the vault
        collateralToken.mint(owner, 100_000 * 1e18);
        collateralToken.approve(address(router), 100_000 * 1e18);
        router.addLiquidity(100_000 * 1e18);
    }

    // ------------------------------------------------------------------
    // OPEN → CLOSE (profit)
    // ------------------------------------------------------------------

    function test_Flow_OpenClose_Profit() public {
        uint256 collateral = 1000 * 1e18;

        collateralToken.mint(trader, collateral);
        vm.startPrank(trader);
        collateralToken.approve(address(router), collateral);
        router.openPosition(token, collateral, 5, true);
        vm.stopPrank();

        oracle.setPrice(token, 2200 * 1e18);

        vm.prank(trader);
        router.closePosition(token, true);

        // PnL = (2200-2000)*5000/2000 = 500. Payout = 1000+500 = 1500.
        assertEq(collateralToken.balanceOf(trader), 1500 * 1e18);
    }

    // ------------------------------------------------------------------
    // OPEN → CLOSE (loss)
    // ------------------------------------------------------------------

    function test_Flow_OpenClose_Loss() public {
        uint256 collateral = 1000 * 1e18;

        collateralToken.mint(trader, collateral);
        vm.startPrank(trader);
        collateralToken.approve(address(router), collateral);
        router.openPosition(token, collateral, 5, true);
        vm.stopPrank();

        oracle.setPrice(token, 1800 * 1e18);

        vm.prank(trader);
        router.closePosition(token, true);

        // PnL loss = 500. Payout = 1000-500 = 500.
        assertEq(collateralToken.balanceOf(trader), 500 * 1e18);
    }

    // ------------------------------------------------------------------
    // LIQUIDATION
    // ------------------------------------------------------------------

    function test_Flow_Liquidation() public {
        uint256 collateral = 1000 * 1e18;

        collateralToken.mint(trader, collateral);
        vm.startPrank(trader);
        collateralToken.approve(address(router), collateral);
        router.openPosition(token, collateral, 10, true);
        vm.stopPrank();

        // Loss at 1800: (2000-1800)*10000/2000 = 1000 = 100% of collateral → liquidatable
        oracle.setPrice(token, 1800 * 1e18);

        vm.prank(liquidator);
        liquidationManager.liquidate(trader, token, true);

        // 5% liquidator reward
        assertEq(collateralToken.balanceOf(liquidator), 50 * 1e18);

        bytes32 key = positionManager.getPositionKey(trader, token, true);
        PositionManager.Position memory pos = positionManager.getPosition(key);
        assertFalse(pos.exists);
    }

    // ------------------------------------------------------------------
    // LP ADD / REMOVE LIQUIDITY
    // ------------------------------------------------------------------

    function test_Flow_AddRemoveLiquidity() public {
        uint256 amount = 10_000 * 1e18;

        collateralToken.mint(trader, amount);
        vm.startPrank(trader);
        collateralToken.approve(address(router), amount);
        router.addLiquidity(amount);
        vm.stopPrank();

        assertEq(vault.totalLiquidity(), 110_000 * 1e18);

        vm.prank(trader);
        router.removeLiquidity(amount);

        assertEq(vault.totalLiquidity(), 100_000 * 1e18);
    }
}
