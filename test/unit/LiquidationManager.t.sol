// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/LiquidationManager.sol";
import "../../src/core/PositionManager.sol";
import "../../src/core/Vault.sol";
import "../../src/core/FundingRateManager.sol";
import "../../src/oracle/PriceOracle.sol";
import "../mocks/MockTaskManager.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract LiquidationManagerTest is Test {
    address constant TASK_MANAGER = 0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9;

    LiquidationManager lm;
    PositionManager pm;
    Vault vault;
    PriceOracle oracle;
    FundingRateManager frm;
    ERC20Mock collateralToken;

    address owner     = address(this);
    address router    = address(0x10);
    address trader    = address(0x20);
    address liquidator = address(0x30);
    address token;

    function setUp() public {
        vm.etch(TASK_MANAGER, address(new MockTaskManager()).code);

        collateralToken = new ERC20Mock();
        token = address(collateralToken);

        oracle = new PriceOracle();
        frm    = new FundingRateManager();
        vault  = new Vault(token, owner);

        pm = new PositionManager(address(vault), address(oracle), address(frm));

        // LiquidationManager now takes only positionManager + fundingManager
        lm = new LiquidationManager(address(pm), address(frm));

        pm.setRouter(router);
        pm.setLiquidationManager(address(lm));
        vault.setPositionManager(address(pm));
        vault.setRouter(router);
        frm.setPositionManager(address(pm));
        frm.setRouter(router);

        oracle.setPrice(token, 2000 * 1e18);

        vm.prank(router);
        vault.deposit(100_000 * 1e18);
        collateralToken.mint(address(vault), 100_000 * 1e18);
    }

    // isLiquidatable() no longer exists — the single-bit FHE check lives
    // entirely inside PositionManager.liquidate(). Tests verify the outcome
    // of a full liquidation instead.

    function test_Liquidate_RemovesPosition() public {
        uint256 collateral = 1000 * 1e18;
        uint256 leverage   = 10;
        bool    isLong     = true;

        vm.prank(router);
        pm.openPosition(trader, token, collateral, leverage, isLong);

        // Size = 10 000. Entry = 2000.
        // Loss at 1800: (2000-1800)*10000/2000 = 1000 > 80% of 1000 collateral → liquidatable.
        oracle.setPrice(token, 1800 * 1e18);

        vm.prank(liquidator);
        lm.liquidate(trader, token, isLong);

        // Position must be deleted
        bytes32 key = pm.getPositionKey(trader, token, isLong);
        PositionManager.Position memory pos = pm.getPosition(key);
        assertFalse(pos.exists);
    }

    function test_Liquidate_PaysLiquidatorReward() public {
        uint256 collateral = 1000 * 1e18;
        uint256 leverage   = 10;
        bool    isLong     = true;

        vm.prank(router);
        pm.openPosition(trader, token, collateral, leverage, isLong);

        oracle.setPrice(token, 1800 * 1e18);

        vm.prank(liquidator);
        lm.liquidate(trader, token, isLong);

        // Reward = 5% of collateral = 50 tokens
        assertEq(collateralToken.balanceOf(liquidator), 50 * 1e18);
    }

    function test_Liquidate_VaultAbsorbsLoss() public {
        uint256 collateral = 1000 * 1e18;
        uint256 leverage   = 10;
        bool    isLong     = true;

        vm.prank(router);
        pm.openPosition(trader, token, collateral, leverage, isLong);

        oracle.setPrice(token, 1800 * 1e18);

        vm.prank(liquidator);
        lm.liquidate(trader, token, isLong);

        // Vault receives collateral minus liquidator reward: 1000 - 50 = 950
        // Total liquidity: 100 000 + 950 = 100 950
        assertEq(vault.totalLiquidity(), 100_950 * 1e18);
    }

    function test_Liquidate_Revert_NotLiquidatable() public {
        uint256 collateral = 1000 * 1e18;
        uint256 leverage   = 10;
        bool    isLong     = true;

        vm.prank(router);
        pm.openPosition(trader, token, collateral, leverage, isLong);

        // Price barely moved — loss is well below 80% threshold
        oracle.setPrice(token, 1990 * 1e18);

        vm.prank(liquidator);
        vm.expectRevert("not liquidatable");
        lm.liquidate(trader, token, isLong);
    }
}
