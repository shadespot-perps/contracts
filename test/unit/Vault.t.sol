// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/Vault.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract VaultTest is Test {
    Vault vault;
    ERC20Mock collateralToken;
    
    address owner = address(this);
    address router = address(0x10);
    address positionManager = address(0x20);
    address trader = address(0x30);

    function setUp() public {
        collateralToken = new ERC20Mock();
        vault = new Vault(address(collateralToken), owner);
        
        vault.setRouter(router);
        vault.setPositionManager(positionManager);
    }

    function test_Initialization() public {
        assertEq(address(vault.collateralToken()), address(collateralToken));
        assertEq(vault.owner(), owner);
        assertEq(vault.router(), router);
        assertEq(vault.positionManager(), positionManager);
    }

    // --- LP FUNCTIONS ---

    function test_Deposit() public {
        uint256 amount = 1000 * 1e18;
        
        vm.prank(router);
        vault.deposit(amount);
        
        assertEq(vault.lpBalance(router), amount);
        assertEq(vault.totalLiquidity(), amount);
        assertEq(vault.availableLiquidity(), amount);
    }

    function test_DepositRevert_OnlyRouter() public {
        vm.prank(trader);
        vm.expectRevert("Not router");
        vault.deposit(100);
    }

    function test_DepositRevert_ZeroAmount() public {
        vm.prank(router);
        vm.expectRevert("Invalid amount");
        vault.deposit(0);
    }

    function test_Withdraw() public {
        uint256 depositAmount = 1000 * 1e18;
        uint256 withdrawAmount = 400 * 1e18;
        
        // Setup initial deposit and mint tokens to vault since Vault transfers out
        collateralToken.mint(address(vault), depositAmount);
        
        vm.prank(router);
        vault.deposit(depositAmount);
        
        vm.prank(router);
        vault.withdraw(withdrawAmount);
        
        assertEq(vault.lpBalance(router), depositAmount - withdrawAmount);
        assertEq(vault.totalLiquidity(), depositAmount - withdrawAmount);
        assertEq(collateralToken.balanceOf(router), withdrawAmount);
    }

    function test_WithdrawRevert_InsufficientBalance() public {
        vm.prank(router);
        vm.expectRevert("Insufficient balance");
        vault.withdraw(100);
    }

    function test_WithdrawRevert_LiquidityLocked() public {
        uint256 depositAmount = 1000 * 1e18;
        collateralToken.mint(address(vault), depositAmount);
        
        vm.prank(router);
        vault.deposit(depositAmount);
        
        // Reserve 800
        vm.prank(positionManager);
        vault.reserveLiquidity(800 * 1e18);
        
        // Attempt to withdraw 400, but only 200 available
        vm.prank(router);
        vm.expectRevert("Liquidity locked");
        vault.withdraw(400 * 1e18);
    }

    // --- POSITION MANAGER FUNCTIONS ---

    function test_ReserveLiquidity() public {
        uint256 depositAmount = 1000 * 1e18;
        vm.prank(router);
        vault.deposit(depositAmount);
        
        uint256 reserveAmount = 500 * 1e18;
        vm.prank(positionManager);
        vault.reserveLiquidity(reserveAmount);
        
        assertEq(vault.totalReserved(), reserveAmount);
        assertEq(vault.availableLiquidity(), depositAmount - reserveAmount);
    }

    function test_ReserveLiquidity_Revert_InsufficientVaultLiquidity() public {
        uint256 reserveAmount = 500 * 1e18;
        vm.prank(positionManager);
        vm.expectRevert("Insufficient vault liquidity");
        vault.reserveLiquidity(reserveAmount);
    }

    function test_ReleaseLiquidity() public {
        uint256 depositAmount = 1000 * 1e18;
        vm.prank(router);
        vault.deposit(depositAmount);
        
        uint256 reserveAmount = 500 * 1e18;
        vm.prank(positionManager);
        vault.reserveLiquidity(reserveAmount);
        
        vm.prank(positionManager);
        vault.releaseLiquidity(300 * 1e18);
        
        assertEq(vault.totalReserved(), 200 * 1e18);
        assertEq(vault.availableLiquidity(), 800 * 1e18);
    }

    function test_PayTrader_ProfitAndCollateral() public {
        uint256 vaultLiquidity = 1000 * 1e18;
        collateralToken.mint(address(vault), vaultLiquidity + 200 * 1e18); // Give vault enough to pay
        
        vm.prank(router);
        vault.deposit(vaultLiquidity);
        
        uint256 profit = 50 * 1e18;
        uint256 collateral = 200 * 1e18;
        
        vm.prank(positionManager);
        vault.payTrader(trader, profit, collateral);
        
        assertEq(collateralToken.balanceOf(trader), profit + collateral);
        assertEq(vault.totalLiquidity(), vaultLiquidity - profit);
    }

    function test_PayTrader_OnlyCollateral() public {
        uint256 vaultLiquidity = 1000 * 1e18;
        collateralToken.mint(address(vault), vaultLiquidity); 
        
        vm.prank(router);
        vault.deposit(vaultLiquidity);
        
        uint256 collateral = 200 * 1e18;
        
        vm.prank(positionManager);
        vault.payTrader(trader, 0, collateral);
        
        assertEq(collateralToken.balanceOf(trader), collateral);
        assertEq(vault.totalLiquidity(), vaultLiquidity); // Liquidity unchanged if profit=0
    }

    function test_ReceiveLoss() public {
        uint256 vaultLiquidity = 1000 * 1e18;
        vm.prank(router);
        vault.deposit(vaultLiquidity);
        
        uint256 loss = 100 * 1e18;
        
        vm.prank(positionManager);
        vault.receiveLoss(loss);
        
        assertEq(vault.totalLiquidity(), vaultLiquidity + loss);
    }
}
