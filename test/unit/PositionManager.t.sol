// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "cofhe-contracts/FHE.sol";
import "../../src/core/PositionManager.sol";
import "../../src/core/Vault.sol";
import "../../src/core/FundingRateManager.sol";
import "../../src/oracle/PriceOracle.sol";
import "../mocks/MockTaskManager.sol";
import "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract PositionManagerTest is Test {
    // CoFHE TaskManager is hardcoded in FHE.sol — etch our mock there.
    address constant TASK_MANAGER = 0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9;

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
        // Etch mock TaskManager so all FHE operations work deterministically.
        // In the mock: handle = plaintext value; getDecryptResultSafe always returns (handle, true).
        vm.etch(TASK_MANAGER, address(new MockTaskManager()).code);

        collateralToken = new ERC20Mock();
        token = address(collateralToken);

        oracle = new PriceOracle();
        fundingRateManager = new FundingRateManager();
        vault = new Vault(token, owner);

        pm = new PositionManager(address(vault), address(oracle), address(fundingRateManager));

        pm.setRouter(router);
        pm.setLiquidationManager(liquidationManager);
        vault.setPositionManager(address(pm));
        vault.setRouter(router);
        fundingRateManager.setPositionManager(address(pm));

        oracle.setPrice(token, 2000 * 1e18);

        vm.prank(router);
        vault.deposit(100_000 * 1e18);
        collateralToken.mint(address(vault), 100_000 * 1e18);
    }

    // ------------------------------------------------------------------
    // OPEN POSITION
    // ------------------------------------------------------------------

    function test_OpenPosition_HappyPath() public {
        uint256 collateral = 1000 * 1e18;
        uint256 leverage   = 5;
        bool    isLong     = true;

        vm.prank(router);
        pm.openPosition(trader, token, collateral, leverage, isLong);

        bytes32 key = pm.getPositionKey(trader, token, isLong);
        PositionManager.Position memory pos = pm.getPosition(key);

        assertTrue(pos.exists);
        assertEq(pos.owner, trader);

        // Decrypt encrypted fields via mock (handle == plaintext value).
        (uint256 decSize,  bool ok1) = FHE.getDecryptResultSafe(pos.size);
        (uint256 decCol,   bool ok2) = FHE.getDecryptResultSafe(pos.collateral);
        (uint256 decPrice, bool ok3) = FHE.getDecryptResultSafe(pos.entryPrice);
        (bool    decLong,  bool ok4) = FHE.getDecryptResultSafe(pos.isLong);
        assertTrue(ok1 && ok2 && ok3 && ok4);

        assertEq(decSize,  5000 * 1e18);
        assertEq(decCol,   collateral);
        assertEq(decPrice, 2000 * 1e18);
        assertTrue(decLong);

        assertEq(vault.totalReserved(), 5000 * 1e18);
        (uint256 longOI,) = fundingRateManager.getOpenInterest(token);
        assertEq(longOI, 5000 * 1e18);
    }

    function test_OpenPosition_Revert_MaxLeverage() public {
        vm.prank(router);
        vm.expectRevert("exceeds max leverage");
        pm.openPosition(trader, token, 1000, 11, true);
    }

    // ------------------------------------------------------------------
    // CLOSE POSITION
    // ------------------------------------------------------------------

    function test_ClosePosition_Profit() public {
        uint256 collateral = 1000 * 1e18;
        uint256 leverage   = 5;
        bool    isLong     = true;

        vm.prank(router);
        pm.openPosition(trader, token, collateral, leverage, isLong);

        // Price up 10% → 2200
        oracle.setPrice(token, 2200 * 1e18);

        vm.prank(router);
        pm.closePosition(trader, token, isLong);

        // PnL = (2200 - 2000) * 5000 / 2000 = 500
        // Payout = 1000 + 500 = 1500
        assertEq(collateralToken.balanceOf(trader), 1500 * 1e18);

        bytes32 key = pm.getPositionKey(trader, token, isLong);
        PositionManager.Position memory pos = pm.getPosition(key);
        assertFalse(pos.exists);

        assertEq(vault.totalReserved(), 0);
        (uint256 longOI,) = fundingRateManager.getOpenInterest(token);
        assertEq(longOI, 0);
    }

    // ------------------------------------------------------------------
    // CALCULATE PNL
    // calculatePnL returns the absolute magnitude — direction is implicit
    // (encoded in the close/liquidate logic via isLong vs price comparison).
    // ------------------------------------------------------------------

    function test_CalculatePnL_Long() public {
        PositionManager.Position memory pos;
        pos.size       = FHE.asEuint128(5000 * 1e18);
        pos.collateral = FHE.asEuint128(1000 * 1e18);
        pos.entryPrice = FHE.asEuint128(2000 * 1e18);
        pos.isLong     = FHE.asEbool(true);
        pos.indexToken = token;

        // Price up 10% — long profits
        euint128 pnlUp = pm.calculatePnL(pos, 2200 * 1e18);
        (uint256 up, bool ok1) = FHE.getDecryptResultSafe(pnlUp);
        assertTrue(ok1);
        assertEq(up, 500 * 1e18);

        // Price down 10% — long loses; magnitude is still 500
        euint128 pnlDown = pm.calculatePnL(pos, 1800 * 1e18);
        (uint256 down, bool ok2) = FHE.getDecryptResultSafe(pnlDown);
        assertTrue(ok2);
        assertEq(down, 500 * 1e18);
    }

    function test_CalculatePnL_Short() public {
        PositionManager.Position memory pos;
        pos.size       = FHE.asEuint128(5000 * 1e18);
        pos.collateral = FHE.asEuint128(1000 * 1e18);
        pos.entryPrice = FHE.asEuint128(2000 * 1e18);
        pos.isLong     = FHE.asEbool(false);
        pos.indexToken = token;

        // Price down 10% — short profits; magnitude 500
        euint128 pnlDown = pm.calculatePnL(pos, 1800 * 1e18);
        (uint256 down, bool ok1) = FHE.getDecryptResultSafe(pnlDown);
        assertTrue(ok1);
        assertEq(down, 500 * 1e18);

        // Price up 10% — short loses; magnitude 500
        euint128 pnlUp = pm.calculatePnL(pos, 2200 * 1e18);
        (uint256 up, bool ok2) = FHE.getDecryptResultSafe(pnlUp);
        assertTrue(ok2);
        assertEq(up, 500 * 1e18);
    }
}
