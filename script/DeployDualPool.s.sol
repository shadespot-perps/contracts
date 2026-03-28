// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/oracle/PriceOracle.sol";
import "../src/core/FundingRateManager.sol";
import "../src/core/Vault.sol";
import "../src/core/FHEVault.sol";
import "../src/core/PositionManager.sol";
import "../src/core/LiquidationManager.sol";
import "../src/trading/OrderManager.sol";
import "../src/trading/Router.sol";
import "../src/trading/FHERouter.sol";
import "../src/tokens/MockUSDC.sol";
import "../src/tokens/MockFHEToken.sol";

/**
 * @title DeployDualPool
 * @notice Deploys both ShadeSpot trading pools from a single script.
 *
 * Pool 1 — Standard (USDC collateral / ETH trade)
 *   Vault           → plaintext ERC-20 accounting
 *   Router          → standard ERC-20 transfers
 *
 * Pool 2 — FHE (Encrypted ERC-20 collateral / ETH trade)
 *   FHEVault        → FHE-encrypted LP accounting (euint128)
 *   FHERouter       → encrypted token transfers
 *
 * Shared per pool:
 *   PriceOracle, FundingRateManager, PositionManager,
 *   OrderManager, LiquidationManager
 *
 * Usage:
 *   forge script script/DeployDualPool.s.sol \
 *       --rpc-url <RPC_URL> --broadcast --private-key <PK>
 *
 * Environment variables:
 *   PRIVATE_KEY             — deployer private key (required)
 *   INDEX_TOKEN             — ETH token address used for price feed / position keys (required)
 *   COLLATERAL_TOKEN_USDC   — Pool 1 collateral; if unset, MockUSDC is deployed automatically
 *   COLLATERAL_TOKEN_FHE    — Pool 2 collateral; if unset, MockFHEToken is deployed automatically
 */
contract DeployDualPool is Script {

    // ── Pool 1 contracts ────────────────────────────────────────────────────
    PriceOracle        public oracle1;
    FundingRateManager public fundingManager1;
    Vault              public vault1;
    PositionManager    public positionManager1;
    OrderManager       public orderManager1;
    LiquidationManager public liquidationManager1;
    Router             public router1;

    // ── Pool 2 contracts ────────────────────────────────────────────────────
    PriceOracle        public oracle2;
    FundingRateManager public fundingManager2;
    FHEVault           public vault2;
    PositionManager    public positionManager2;
    OrderManager       public orderManager2;
    LiquidationManager public liquidationManager2;
    FHERouter          public router2;

    function run() external {
        address indexToken_ = vm.envAddress("INDEX_TOKEN");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // Deploy mock tokens if real addresses not provided
        address usdcToken = vm.envOr("COLLATERAL_TOKEN_USDC", address(0));
        if (usdcToken == address(0)) {
            usdcToken = address(new MockUSDC());
            console2.log("MockUSDC deployed:   ", usdcToken);
        }

        address fheToken = vm.envOr("COLLATERAL_TOKEN_FHE", address(0));
        if (fheToken == address(0)) {
            fheToken = address(new MockFHEToken("Encrypted USDC", "eUSDC"));
            console2.log("MockFHEToken deployed:", fheToken);
        }

        _deployPool1(usdcToken, deployer, indexToken_);
        _deployPool2(fheToken, deployer, indexToken_);

        vm.stopBroadcast();

        console2.log("\n=== ShadeSpot Dual-Pool deployment complete ===");
        console2.log("\n--- Pool 1 (USDC / ETH) ---");
        console2.log("USDC collateral:     ", usdcToken);
        console2.log("PriceOracle:         ", address(oracle1));
        console2.log("FundingRateManager:  ", address(fundingManager1));
        console2.log("Vault:               ", address(vault1));
        console2.log("PositionManager:     ", address(positionManager1));
        console2.log("OrderManager:        ", address(orderManager1));
        console2.log("LiquidationManager:  ", address(liquidationManager1));
        console2.log("Router:              ", address(router1));

        console2.log("\n--- Pool 2 (FHE Token / ETH) ---");
        console2.log("FHE collateral:      ", fheToken);
        console2.log("PriceOracle:         ", address(oracle2));
        console2.log("FundingRateManager:  ", address(fundingManager2));
        console2.log("FHEVault:            ", address(vault2));
        console2.log("PositionManager:     ", address(positionManager2));
        console2.log("OrderManager:        ", address(orderManager2));
        console2.log("LiquidationManager:  ", address(liquidationManager2));
        console2.log("FHERouter:           ", address(router2));
        console2.log("\nIndex token (ETH):   ", indexToken_);
    }

    // ────────────────────────────────────────────────────────────────────────
    // INTERNAL — pool deployment helpers
    // ────────────────────────────────────────────────────────────────────────

    function _deployPool1(address collateralToken, address deployer, address indexToken_) internal {
        oracle1        = new PriceOracle();
        fundingManager1 = new FundingRateManager();
        vault1         = new Vault(collateralToken, deployer);
        positionManager1 = new PositionManager(
            address(vault1),
            address(oracle1),
            address(fundingManager1)
        );
        orderManager1 = new OrderManager(
            address(oracle1),
            address(fundingManager1),
            deployer
        );
        liquidationManager1 = new LiquidationManager(
            address(positionManager1),
            address(fundingManager1)
        );
        router1 = new Router(
            address(positionManager1),
            address(vault1),
            address(orderManager1),
            address(fundingManager1),
            collateralToken,
            indexToken_
        );

        _wirePool1();
    }

    function _wirePool1() internal {
        vault1.setPositionManager(address(positionManager1));
        vault1.setRouter(address(router1));

        positionManager1.setRouter(address(router1));
        positionManager1.setLiquidationManager(address(liquidationManager1));

        fundingManager1.setRouter(address(router1));
        fundingManager1.setPositionManager(address(positionManager1));
        fundingManager1.setLiquidationManager(address(liquidationManager1));

        // Wire OrderManager router
        orderManager1.setRouter(address(router1));
    }

    function _deployPool2(address collateralToken, address deployer, address indexToken_) internal {
        oracle2         = new PriceOracle();
        fundingManager2 = new FundingRateManager();
        vault2          = new FHEVault(collateralToken, deployer);
        positionManager2 = new PositionManager(
            address(vault2),
            address(oracle2),
            address(fundingManager2)
        );
        orderManager2 = new OrderManager(
            address(oracle2),
            address(fundingManager2),
            deployer
        );
        liquidationManager2 = new LiquidationManager(
            address(positionManager2),
            address(fundingManager2)
        );
        router2 = new FHERouter(
            address(positionManager2),
            address(vault2),
            address(orderManager2),
            address(fundingManager2),
            collateralToken,
            indexToken_
        );

        _wirePool2();
    }

    function _wirePool2() internal {
        vault2.setPositionManager(address(positionManager2));
        vault2.setRouter(address(router2));

        positionManager2.setRouter(address(router2));
        positionManager2.setLiquidationManager(address(liquidationManager2));

        fundingManager2.setRouter(address(router2));
        fundingManager2.setPositionManager(address(positionManager2));
        fundingManager2.setLiquidationManager(address(liquidationManager2));

        orderManager2.setRouter(address(router2));
    }
}
