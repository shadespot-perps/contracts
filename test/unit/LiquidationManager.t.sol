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
        vault.deposit(router, 100_000 * 1e18);
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
        vm.prank(liquidator);
        lm.finalizeLiquidation(trader, token, isLong, true, "", collateral, "", collateral * leverage, "");

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
        vm.prank(liquidator);
        lm.finalizeLiquidation(trader, token, isLong, true, "", collateral, "", collateral * leverage, "");

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
        vm.prank(liquidator);
        lm.finalizeLiquidation(trader, token, isLong, true, "", collateral, "", collateral * leverage, "");

        // Vault receives collateral minus liquidator reward via receiveLoss: +950
        // Then payTrader(liquidator, 0, 50) decrements totalLiquidity: -50
        // Total liquidity: 100_000 + 950 - 50 = 100_900
        assertEq(vault.totalLiquidity(), 100_900 * 1e18);
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
        lm.liquidate(trader, token, isLong);

        vm.prank(liquidator);
        vm.expectRevert("not liquidatable");
        lm.finalizeLiquidation(trader, token, isLong, false, "", collateral, "", collateral * leverage, "");
    }

    // ------------------------------------------------------------------
    // setLiquidationFee
    // ------------------------------------------------------------------

    function test_SetLiquidationFee_UpdatesState() public {
        uint256 fee = 0.01 ether;
        lm.setLiquidationFee(fee);
        assertEq(lm.liquidationFee(), fee);
    }

    function test_SetLiquidationFee_EmitsEvent() public {
        uint256 fee = 0.005 ether;
        vm.expectEmit(false, false, false, true);
        emit LiquidationManager.LiquidationFeeSet(fee);
        lm.setLiquidationFee(fee);
    }

    function test_SetLiquidationFee_CanBeSetToZero() public {
        lm.setLiquidationFee(0.01 ether);
        lm.setLiquidationFee(0);
        assertEq(lm.liquidationFee(), 0);
    }

    function test_SetLiquidationFee_Revert_NotOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert("Not owner");
        lm.setLiquidationFee(0.01 ether);
    }

    function test_SetLiquidationFee_EnforcedOnLiquidate() public {
        uint256 collateral = 1000 * 1e18;
        uint256 leverage   = 10;
        bool    isLong     = true;
        uint256 fee        = 0.01 ether;

        lm.setLiquidationFee(fee);

        vm.prank(router);
        pm.openPosition(trader, token, collateral, leverage, isLong);
        oracle.setPrice(token, 1800 * 1e18);

        // Should revert when no ETH is sent
        vm.prank(liquidator);
        vm.expectRevert("Insufficient ETH fee");
        lm.liquidate(trader, token, isLong);

        // Should succeed when correct fee is sent
        vm.deal(liquidator, fee);
        vm.prank(liquidator);
        lm.liquidate{value: fee}(trader, token, isLong);
    }

    function test_SetLiquidationFee_AccumulatesCollectedFees() public {
        uint256 collateral = 1000 * 1e18;
        uint256 leverage   = 10;
        bool    isLong     = true;
        uint256 fee        = 0.01 ether;

        lm.setLiquidationFee(fee);

        vm.prank(router);
        pm.openPosition(trader, token, collateral, leverage, isLong);
        oracle.setPrice(token, 1800 * 1e18);

        vm.deal(liquidator, fee);
        vm.prank(liquidator);
        lm.liquidate{value: fee}(trader, token, isLong);

        assertEq(lm.collectedFees(), fee);
    }
}
