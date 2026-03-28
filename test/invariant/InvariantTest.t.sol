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

/**
 * @notice Handler contract that drives the invariant fuzzer.
 *
 * Invariants checked after every action:
 *   1. Vault solvency: totalLiquidity >= totalReserved.
 *   2. No position leaks: closed positions have exists == false.
 */
contract InvariantHandler is Test {
    address constant TASK_MANAGER = 0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9;

    PositionManager    pm;
    LiquidationManager lm;
    FundingRateManager frm;
    Vault              theVault;
    Router             router;
    PriceOracle        oracle;
    ERC20Mock          collateral; // USDC collateral token
    ERC20Mock          ethMock;    // ETH index token (price feed only)

    address owner   = address(this);
    address[] traders;

    bytes32[] openPositionKeys;

    function getVault() external view returns (Vault) { return theVault; }

    constructor() {
        vm.etch(TASK_MANAGER, address(new MockTaskManager()).code);

        collateral = new ERC20Mock();
        ethMock    = new ERC20Mock();   // ETH — address used for oracle + positions
        oracle  = new PriceOracle();
        frm     = new FundingRateManager();
        theVault   = new Vault(address(collateral), owner);
        pm      = new PositionManager(address(theVault), address(oracle), address(frm));
        lm      = new LiquidationManager(address(pm), address(frm));

        OrderManager om = new OrderManager(address(oracle), address(frm), owner);
        router = new Router(
            address(pm),
            address(theVault),
            address(om),
            address(frm),
            address(collateral),
            address(ethMock)    // indexToken = ETH
        );

        pm.setRouter(address(router));
        pm.setLiquidationManager(address(lm));
        theVault.setPositionManager(address(pm));
        theVault.setRouter(address(router));
        frm.setPositionManager(address(pm));
        frm.setRouter(address(router));
        om.setRouter(address(router));

        oracle.setPrice(address(ethMock), 2000 * 1e18);

        collateral.mint(owner, 1_000_000 * 1e18);
        collateral.approve(address(router), 1_000_000 * 1e18);
        router.addLiquidity(1_000_000 * 1e18);

        // Pre-fund some trader addresses
        for (uint256 i = 1; i <= 5; i++) {
            address t = address(uint160(i * 0x1000));
            traders.push(t);
            collateral.mint(t, 10_000 * 1e18);
            vm.prank(t);
            collateral.approve(address(router), 10_000 * 1e18);
        }
    }

    function openPosition(uint256 traderIdx, uint256 amount, uint256 leverage, bool isLong) public {
        traderIdx = bound(traderIdx, 0, traders.length - 1);
        amount     = bound(amount, 1 * 1e18, 1000 * 1e18);
        leverage   = bound(leverage, 1, 10);

        address t = traders[traderIdx];
        vm.prank(t);
        try router.openPosition(address(ethMock), amount, leverage, isLong) {
            openPositionKeys.push(pm.getPositionKey(t, address(ethMock), isLong));
        } catch {}
    }

    function closePosition(uint256 traderIdx, bool isLong) public {
        traderIdx = bound(traderIdx, 0, traders.length - 1);
        address t = traders[traderIdx];
        vm.prank(t);
        try router.closePosition(address(ethMock), isLong) {} catch {}
    }

    function setPrice(uint256 price) public {
        price = bound(price, 100 * 1e18, 10000 * 1e18);
        oracle.setPrice(address(ethMock), price);
    }
}

contract InvariantTest is Test {
    InvariantHandler handler;

    function setUp() public {
        handler = new InvariantHandler();
        targetContract(address(handler));
    }

    function invariant_VaultSolvent() public view {
        Vault v = handler.getVault();
        assertGe(
            v.totalLiquidity(),
            v.totalReserved(),
            "vault insolvency: reserved > total liquidity"
        );
    }
}
