// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/oracle/PriceOracle.sol";
import "../src/core/FundingRateManager.sol";
import "../src/core/FHEVault.sol";
import "../src/core/PositionManager.sol";
import "../src/core/LiquidationManager.sol";
import "../src/trading/OrderManager.sol";
import "../src/trading/FHERouter.sol";

/**
 * @title DeployPool2Only
 * @notice Re-deploys only Pool 2 (FHE token / ETH) without touching Pool 1
 *         or the existing FHE token contract.
 *
 * Usage:
 *   forge script script/DeployPool2Only.s.sol \
 *       --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
 *       --broadcast \
 *       --private-key $PRIVATE_KEY
 *
 * Required env vars (same as .env):
 *   PRIVATE_KEY                — deployer key
 *   INDEX_TOKEN                — ETH index token address
 *   COLLATERAL_TOKEN_FHE       — existing FHE token address (not redeployed)
 */
contract DeployPool2Only is Script {
    function run() external {
        address indexToken  = vm.envAddress("INDEX_TOKEN");
        address fheToken    = vm.envAddress("COLLATERAL_TOKEN_FHE");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        PriceOracle        oracle      = new PriceOracle();
        FundingRateManager fundingMgr  = new FundingRateManager();
        FHEVault           vault       = new FHEVault(fheToken, deployer);
        PositionManager    positionMgr = new PositionManager(
            address(vault),
            address(oracle),
            address(fundingMgr)
        );
        OrderManager orderMgr = new OrderManager(
            address(oracle),
            address(fundingMgr),
            deployer
        );
        LiquidationManager liqMgr = new LiquidationManager(
            address(positionMgr),
            address(fundingMgr)
        );
        FHERouter router = new FHERouter(
            address(positionMgr),
            address(vault),
            address(orderMgr),
            address(fundingMgr),
            fheToken,
            indexToken
        );

        // Wire all contracts together
        vault.setPositionManager(address(positionMgr));
        vault.setRouter(address(router));

        positionMgr.setRouter(address(router));
        positionMgr.setLiquidationManager(address(liqMgr));

        fundingMgr.setRouter(address(router));
        fundingMgr.setPositionManager(address(positionMgr));
        fundingMgr.setLiquidationManager(address(liqMgr));

        orderMgr.setRouter(address(router));

        vm.stopBroadcast();

        // Print new addresses — pool2-redeploy.ts reads these from the broadcast JSON
        console2.log("=== Pool 2 redeployed (updated contracts) ===");
        console2.log("ORACLE:           ", address(oracle));
        console2.log("FUNDING_MANAGER:  ", address(fundingMgr));
        console2.log("FHE_VAULT:        ", address(vault));
        console2.log("POSITION_MANAGER: ", address(positionMgr));
        console2.log("ORDER_MANAGER:    ", address(orderMgr));
        console2.log("LIQUIDATION_MGR:  ", address(liqMgr));
        console2.log("FHE_ROUTER:       ", address(router));
        console2.log("\nNext steps:");
        console2.log("  npm run pool2:redeploy  (auto-updates config.ts)");
        console2.log("  npm run pool2:setup      (re-grant setOperator)");
        console2.log("  npm run pool2:add-liquidity");
        console2.log("  npm run pool2:open");
    }
}
