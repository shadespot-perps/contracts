// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/oracle/PriceOracle.sol";
import "../src/core/FundingRateManager.sol";
import "../src/core/Vault.sol";
import "../src/core/PositionManager.sol";
import "../src/core/LiquidationManager.sol";
import "../src/trading/OrderManager.sol";
import "../src/trading/Router.sol";

/**
 * @title Deploy
 * @notice Full deployment script for ShadeSpot protocol.
 *
 * Deployment order:
 *   1. PriceOracle
 *   2. FundingRateManager
 *   3. Vault
 *   4. PositionManager
 *   5. OrderManager
 *   6. LiquidationManager
 *   7. Router
 *
 * Then wires all cross-contract references.
 *
 * Usage:
 *   forge script script/Deploy.s.sol --rpc-url <RPC_URL> --broadcast --private-key <PK>
 *
 * Environment variables:
 *   COLLATERAL_TOKEN  - address of the ERC-20 used as collateral (required)
 *   DEPLOYER_ADDRESS  - deployer address (optional, defaults to msg.sender)
 */
contract Deploy is Script {

    // ── Deployed addresses (filled during run) ──────────────────────────────
    PriceOracle         public oracle;
    FundingRateManager  public fundingManager;
    Vault               public vault;
    PositionManager     public positionManager;
    OrderManager        public orderManager;
    LiquidationManager  public liquidationManager;
    Router              public router;

    function run() external {
        address collateralToken = vm.envAddress("COLLATERAL_TOKEN");
        address indexToken_     = vm.envAddress("INDEX_TOKEN");
        uint256 deployerKey     = vm.envUint("PRIVATE_KEY");
        address deployer        = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // ── 1. Oracle ────────────────────────────────────────────────────────
        oracle = new PriceOracle();
        console2.log("PriceOracle:        ", address(oracle));

        // ── 2. FundingRateManager ────────────────────────────────────────────
        fundingManager = new FundingRateManager();
        console2.log("FundingRateManager: ", address(fundingManager));

        // ── 3. Vault ─────────────────────────────────────────────────────────
        vault = new Vault(collateralToken, deployer);
        console2.log("Vault:              ", address(vault));

        // ── 4. PositionManager ───────────────────────────────────────────────
        positionManager = new PositionManager(
            address(vault),
            address(oracle),
            address(fundingManager)
        );
        console2.log("PositionManager:    ", address(positionManager));

        // ── 5. OrderManager ──────────────────────────────────────────────────
        orderManager = new OrderManager(
            address(oracle),
            address(fundingManager),
            deployer
        );
        console2.log("OrderManager:       ", address(orderManager));

        // ── 6. LiquidationManager ────────────────────────────────────────────
        liquidationManager = new LiquidationManager(
            address(positionManager),
            address(fundingManager)
        );
        console2.log("LiquidationManager: ", address(liquidationManager));

        // ── 7. Router ────────────────────────────────────────────────────────
        router = new Router(
            address(positionManager),
            address(vault),
            address(orderManager),
            address(fundingManager),
            collateralToken,
            indexToken_
        );
        console2.log("Router:             ", address(router));

        // ── Wire cross-contract references ───────────────────────────────────

        // Vault
        vault.setPositionManager(address(positionManager));
        vault.setRouter(address(router));

        // PositionManager
        positionManager.setRouter(address(router));
        positionManager.setLiquidationManager(address(liquidationManager));

        // FundingRateManager
        fundingManager.setRouter(address(router));
        fundingManager.setPositionManager(address(positionManager));
        fundingManager.setLiquidationManager(address(liquidationManager));

        vm.stopBroadcast();

        console2.log("\n=== ShadeSpot deployment complete ===");
        console2.log("Collateral token:   ", collateralToken);
        console2.log("Index token (ETH):  ", indexToken_);
    }
}
