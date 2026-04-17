// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/Vault.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract VaultTest is Test {
    Vault vault;
    ERC20Mock collateralToken;

    address owner           = address(this);
    address router          = address(0x10);
    address positionManager = address(0x20);
    address trader          = address(0x30);
    address lp              = address(0x40);

    function setUp() public {
        collateralToken = new ERC20Mock();
        vault = new Vault(address(collateralToken), owner);

        vault.setRouter(router);
        vault.setPositionManager(positionManager);
    }

    // ----------------------------------------------------------------
    // Initialization
    // ----------------------------------------------------------------

    function test_Initialization() public {
        assertEq(address(vault.collateralToken()), address(collateralToken));
        assertEq(vault.owner(), owner);
        assertEq(vault.router(), router);
        assertEq(vault.positionManager(), positionManager);
        assertEq(vault.name(), "ShadeSpot LP");
        assertEq(vault.symbol(), "SLP");
    }

    // ----------------------------------------------------------------
    // deposit — share minting
    // ----------------------------------------------------------------

    function test_Deposit_FirstDeposit_SharesEqualAmount() public {
        uint256 amount = 1000 * 1e18;

        vm.prank(router);
        vault.deposit(lp, amount);

        assertEq(vault.balanceOf(lp), amount);
        assertEq(vault.totalSupply(), amount);
        assertEq(vault.totalLiquidity(), amount);
    }

    function test_Deposit_SecondDeposit_SharesProportional() public {
        uint256 first  = 1000 * 1e18;
        uint256 second = 500 * 1e18;

        vm.prank(router);
        vault.deposit(lp, first);

        address lp2 = address(0x50);
        vm.prank(router);
        vault.deposit(lp2, second);

        // shares = 500 * 1000 / 1000 = 500
        assertEq(vault.balanceOf(lp2), 500 * 1e18);
        assertEq(vault.totalSupply(), 1500 * 1e18);
        assertEq(vault.totalLiquidity(), 1500 * 1e18);
    }

    function test_Deposit_SharesGrowWhenPoolProfits() public {
        uint256 amount = 1000 * 1e18;
        vm.prank(router);
        vault.deposit(lp, amount);

        // Pool earns 500 (trader loss)
        vm.prank(positionManager);
        vault.receiveLoss(500 * 1e18);
        // totalLiquidity = 1500, totalSupply = 1000

        address lp2 = address(0x50);
        vm.prank(router);
        vault.deposit(lp2, 1500 * 1e18);
        // shares = 1500 * 1000 / 1500 = 1000
        assertEq(vault.balanceOf(lp2), 1000 * 1e18);
    }

    function test_Deposit_Revert_OnlyRouter() public {
        vm.prank(trader);
        vm.expectRevert("Not router");
        vault.deposit(lp, 100);
    }

    function test_Deposit_Revert_ZeroAmount() public {
        vm.prank(router);
        vm.expectRevert("Invalid amount");
        vault.deposit(lp, 0);
    }

    // ----------------------------------------------------------------
    // withdraw — share redemption
    // ----------------------------------------------------------------

    function test_Withdraw_FullRedemption() public {
        uint256 amount = 1000 * 1e18;
        collateralToken.mint(address(vault), amount);

        vm.prank(router);
        vault.deposit(lp, amount);

        vm.prank(router);
        vault.withdraw(lp, amount); // shares == amount on first deposit

        assertEq(vault.balanceOf(lp), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.totalLiquidity(), 0);
        assertEq(collateralToken.balanceOf(lp), amount);
    }

    function test_Withdraw_PartialRedemption() public {
        uint256 amount = 1000 * 1e18;
        collateralToken.mint(address(vault), amount);

        vm.prank(router);
        vault.deposit(lp, amount);

        vm.prank(router);
        vault.withdraw(lp, 400 * 1e18); // redeem 400 shares → 400 tokens

        assertEq(vault.balanceOf(lp), 600 * 1e18);
        assertEq(vault.totalLiquidity(), 600 * 1e18);
        assertEq(collateralToken.balanceOf(lp), 400 * 1e18);
    }

    function test_Withdraw_ProfitAccrued_MoreTokensReturned() public {
        uint256 amount = 1000 * 1e18;
        collateralToken.mint(address(vault), 1500 * 1e18);

        vm.prank(router);
        vault.deposit(lp, amount);

        // Pool earns 500 from trader loss
        vm.prank(positionManager);
        vault.receiveLoss(500 * 1e18);
        // totalLiquidity=1500, totalSupply=1000

        // Redeem all 1000 shares → 1000 * 1500 / 1000 = 1500 tokens
        vm.prank(router);
        vault.withdraw(lp, 1000 * 1e18);

        assertEq(collateralToken.balanceOf(lp), 1500 * 1e18);
    }

    function test_Withdraw_Revert_InsufficientShares() public {
        vm.prank(router);
        vm.expectRevert("Insufficient shares");
        vault.withdraw(lp, 100);
    }

    function test_Withdraw_Revert_LiquidityLocked() public {
        uint256 amount = 1000 * 1e18;
        collateralToken.mint(address(vault), amount);

        vm.prank(router);
        vault.deposit(lp, amount);

        vm.prank(positionManager);
        vault.reserveLiquidity(800 * 1e18, address(this));

        // 400 shares → 400 tokens, but only 200 available
        vm.prank(router);
        vm.expectRevert("Liquidity locked");
        vault.withdraw(lp, 400 * 1e18);
    }

    // ----------------------------------------------------------------
    // Position manager functions (unchanged behaviour)
    // ----------------------------------------------------------------

    function test_ReserveLiquidity() public {
        vm.prank(router);
        vault.deposit(lp, 1000 * 1e18);

        vm.prank(positionManager);
        vault.reserveLiquidity(500 * 1e18, address(this));

        assertEq(vault.totalReserved(), 500 * 1e18);
        assertEq(vault.availableLiquidity(), 500 * 1e18);
    }

    function test_ReserveLiquidity_Revert_InsufficientVaultLiquidity() public {
        vm.prank(positionManager);
        vm.expectRevert("Insufficient vault liquidity");
        vault.reserveLiquidity(500 * 1e18, address(this));
    }

    function test_ReleaseLiquidity() public {
        vm.prank(router);
        vault.deposit(lp, 1000 * 1e18);

        vm.prank(positionManager);
        vault.reserveLiquidity(500 * 1e18, address(this));

        vm.prank(positionManager);
        vault.releaseLiquidity(300 * 1e18);

        assertEq(vault.totalReserved(), 200 * 1e18);
        assertEq(vault.availableLiquidity(), 800 * 1e18);
    }

    function test_PayTrader_ProfitAndCollateral() public {
        collateralToken.mint(address(vault), 1200 * 1e18);

        vm.prank(router);
        vault.deposit(lp, 1000 * 1e18);

        vm.prank(positionManager);
        vault.payTrader(trader, 50 * 1e18, 200 * 1e18);

        assertEq(collateralToken.balanceOf(trader), 250 * 1e18);
        assertEq(vault.totalLiquidity(), 950 * 1e18);
    }

    function test_PayTrader_OnlyCollateral() public {
        collateralToken.mint(address(vault), 1000 * 1e18);

        vm.prank(router);
        vault.deposit(lp, 1000 * 1e18);

        vm.prank(positionManager);
        vault.payTrader(trader, 0, 200 * 1e18);

        assertEq(collateralToken.balanceOf(trader), 200 * 1e18);
        assertEq(vault.totalLiquidity(), 1000 * 1e18);
    }

    function test_ReceiveLoss() public {
        vm.prank(router);
        vault.deposit(lp, 1000 * 1e18);

        vm.prank(positionManager);
        vault.receiveLoss(100 * 1e18);

        assertEq(vault.totalLiquidity(), 1100 * 1e18);
    }
}
