// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../src/oracle/PriceOracle.sol";
import "../src/core/FHEFundingRateManager.sol";
import "../src/core/FHEVault.sol";
import "../src/core/PositionManager.sol";
import "../src/core/LiquidationManager.sol";
import "../src/trading/FHEOrderManager.sol";
import "../src/trading/FHERouter.sol";
import "../src/tokens/MockFHEToken.sol";

contract DeployShadeSpot is Script {

    PriceOracle        public oracle;
    FHEFundingRateManager public fundingManager;
    FHEVault           public vault;
    PositionManager    public positionManager;
    FHEOrderManager    public orderManager;
    LiquidationManager public liquidationManager;
    FHERouter          public router;

    function run() external {
        address indexToken_ = vm.envAddress("INDEX_TOKEN");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        address fheToken = vm.envOr("COLLATERAL_TOKEN_FHE", address(0));
        if (fheToken == address(0)) {
            fheToken = address(new MockFHEToken("Encrypted USDC", "eUSDC"));
            console2.log("MockFHEToken deployed:", fheToken);
        }

        oracle         = new PriceOracle();
        fundingManager = new FHEFundingRateManager();
        vault          = new FHEVault(fheToken, deployer);
        positionManager = new PositionManager(
            address(vault),
            address(oracle)
        );
        orderManager = new FHEOrderManager(
            address(oracle),
            address(fundingManager),
            deployer
        );
        liquidationManager = new LiquidationManager(
            address(positionManager),
            address(fundingManager)
        );
        router = new FHERouter(
            address(positionManager),
            address(vault),
            address(orderManager),
            address(fundingManager),
            fheToken,
            indexToken_
        );

        vault.setPositionManager(address(positionManager));
        vault.setRouter(address(router));
        positionManager.setFHEFundingManager(address(fundingManager));
        fundingManager.setPositionManager(address(positionManager));

        positionManager.setFheRouter(address(router));
        positionManager.setLiquidationManager(address(liquidationManager));

        orderManager.setRouter(address(router));

        vm.stopBroadcast();

        console2.log("\n=== ShadeSpot FHE deployment complete ===");
        console2.log("FHE collateral:      ", fheToken);
        console2.log("PriceOracle:         ", address(oracle));
        console2.log("FHEFundingManager:   ", address(fundingManager));
        console2.log("FHEVault:            ", address(vault));
        console2.log("PositionManager:     ", address(positionManager));
        console2.log("FHEOrderManager:     ", address(orderManager));
        console2.log("LiquidationManager:  ", address(liquidationManager));
        console2.log("FHERouter:           ", address(router));
        console2.log("\nIndex token (ETH):   ", indexToken_);
    }
}
