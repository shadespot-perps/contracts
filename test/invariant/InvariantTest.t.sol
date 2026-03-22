// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/core/Vault.sol";
import "../../src/core/PositionManager.sol";
import "../../src/core/FundingRateManager.sol";
import "../../src/core/LiquidationManager.sol";
import "../../src/trading/Router.sol";
import "../../src/trading/OrderManager.sol";
import "../../src/oracle/PriceOracle.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

// Setup a Handler/Target to fuzz stateful interactions
contract Handler is Test {
    Vault public vault;
    PositionManager public pm;
    Router public router;
    PriceOracle public oracle;
    FundingRateManager public frm;
    
    ERC20Mock public collateralData;
    address public token;

    constructor(
        Vault _vault,
        PositionManager _pm,
        Router _router,
        PriceOracle _oracle,
        FundingRateManager _frm,
        ERC20Mock _collec
    ) {
        vault = _vault;
        pm = _pm;
        router = _router;
        oracle = _oracle;
        frm = _frm;
        collateralData = _collec;
        token = address(_collec);
    }

    // Stateful functions for fuzzer to call
    function addLiquidity(uint256 amount) public {
        amount = bound(amount, 1e18, 1_000_000 * 1e18);
        collateralData.mint(msg.sender, amount);
        
        vm.startPrank(msg.sender);
        collateralData.approve(address(router), amount);
        router.addLiquidity(amount);
        vm.stopPrank();
    }

    function changePrice(uint256 newPrice) public {
        newPrice = bound(newPrice, 100 * 1e18, 10_000 * 1e18); // Stay between $100 and $10k
        oracle.setPrice(token, newPrice);
    }

    function warpTime(uint256 extraTime) public {
        extraTime = bound(extraTime, 1, 48 hours); // Max skip 2 days
        vm.warp(block.timestamp + extraTime);
    }
}

contract ProtocolInvariantTest is Test {
    Vault vault;
    PositionManager pm;
    Router router;
    PriceOracle oracle;
    FundingRateManager frm;
    OrderManager om;
    LiquidationManager lm;
    ERC20Mock collateral;
    
    Handler handler;
    address owner = address(this);
    address token;

    function setUp() public {
        collateral = new ERC20Mock();
        token = address(collateral);
        oracle = new PriceOracle();
        frm = new FundingRateManager();
        vault = new Vault(token, owner);
        pm = new PositionManager(address(vault), address(oracle), address(frm));
        om = new OrderManager(address(oracle), address(frm), owner);
        router = new Router(address(pm), address(vault), address(om), address(frm), address(collateral));
        lm = new LiquidationManager(address(pm), address(oracle), address(vault), address(frm));
        
        // Wiring
        pm.setRouter(address(router));
        pm.setLiquidationManager(address(lm));
        vault.setRouter(address(router));
        vault.setPositionManager(address(pm));
        frm.setRouter(address(router));
        frm.setPositionManager(address(pm));
        frm.setLiquidationManager(address(lm)); // Fix
        om.setRouter(address(router));
        
        oracle.setPrice(token, 2000 * 1e18);

        handler = new Handler(vault, pm, router, oracle, frm, collateral);
        targetContract(address(handler));
    }

    function invariant_A_VaultSolvency() public {
        // Total liquidity should always be >= totalReserved
        assertGe(vault.totalLiquidity(), vault.totalReserved());
    }

    function invariant_B_VaultTokenBacking() public {
        // Vault token balance must be >= totalLiquidity
        uint256 tokenBal = collateral.balanceOf(address(vault));
        assertGe(tokenBal, vault.totalLiquidity());
    }
}
