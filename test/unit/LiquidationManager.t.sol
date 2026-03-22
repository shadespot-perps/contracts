// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/LiquidationManager.sol";
import "../../src/core/PositionManager.sol";
import "../../src/core/Vault.sol";
import "../../src/core/FundingRateManager.sol";
import "../../src/oracle/PriceOracle.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract LiquidationManagerTest is Test {
    LiquidationManager lm;
    PositionManager pm;
    Vault vault;
    PriceOracle oracle;
    FundingRateManager frm;
    ERC20Mock collateralToken;

    address owner = address(this);
    address router = address(0x10);
    address trader = address(0x20);
    address liquidator = address(0x30);
    address token;

    function setUp() public {
        collateralToken = new ERC20Mock();
        token = address(collateralToken);

        oracle = new PriceOracle();
        frm = new FundingRateManager();
        vault = new Vault(token, owner);
        
        pm = new PositionManager(address(vault), address(oracle), address(frm));
        lm = new LiquidationManager(address(pm), address(oracle), address(vault), address(frm));
        
        // Wires
        pm.setRouter(router);
        pm.setLiquidationManager(address(lm));
        vault.setPositionManager(address(pm));
        vault.setRouter(router);
        frm.setPositionManager(address(pm));
        frm.setRouter(router);
        frm.setLiquidationManager(address(lm)); // Fix applied earlier
        
        // Oracle
        oracle.setPrice(token, 2000 * 1e18); // $2000 per token
        
        // Provide vault liquidity
        vm.prank(router);
        vault.deposit(100_000 * 1e18);
        collateralToken.mint(address(vault), 100_000 * 1e18);
    }

    function test_IsLiquidatable() public {
        uint256 collateral = 1000 * 1e18;
        uint256 leverage = 10;
        bool isLong = true;

        vm.prank(router);
        pm.openPosition(trader, token, collateral, leverage, isLong);
        // Size = 10k, entry = 2000. 
        // Liquidation at 80% loss means loss >= 800.
        // Price change needed: loss = (entry - price) * size / entry = (2000 - price) * 10000 / 2000 = (2000 - price) * 5
        // 800 = (2000 - price) * 5  => 160 = 2000 - price => price = 1840

        // Price goes down to 1840
        oracle.setPrice(token, 1840 * 1e18);
        assertTrue(lm.isLiquidatable(trader, token, true));
        
        // Price goes down to 1841 (loss = 795, not liquidatable)
        oracle.setPrice(token, 1841 * 1e18);
        assertFalse(lm.isLiquidatable(trader, token, true));
    }

    function test_Liquidate() public {
        uint256 collateral = 1000 * 1e18;
        uint256 leverage = 10;
        bool isLong = true;

        vm.prank(router);
        pm.openPosition(trader, token, collateral, leverage, isLong);
        
        // Price goes down to 1800 (1000 loss)
        oracle.setPrice(token, 1800 * 1e18);
        
        // Liquidate
        vm.prank(liquidator);
        lm.liquidate(trader, token, isLong);
        
        // Collateral is 1000. Reward = 5% = 50.
        // Liquidator should receive 50 tokens directly.
        assertEq(collateralToken.balanceOf(liquidator), 50 * 1e18);
        
        // Position should be removed
        bytes32 key = pm.getPositionKey(trader, token, isLong);
        PositionManager.Position memory pos = pm.getPosition(key);
        assertEq(pos.size, 0);

        // Vault should have absorbed collateral minus reward (1000 - 50 = 950) 
        // Initial liquidity + 950 = 100_950
        assertEq(vault.totalLiquidity(), 100_950 * 1e18);
    }
}
