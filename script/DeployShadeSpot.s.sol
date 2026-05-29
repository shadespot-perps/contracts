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
import "../src/tokens/MockPlainERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract DeployShadeSpot is Script {

    PriceOracle        public oracle;
    FHEFundingRateManager public fundingManager;
    FHEVault           public vault;
    PositionManager    public positionManager;
    FHEOrderManager    public orderManager;
    LiquidationManager public liquidationManager;
    FHERouter          public router;

    function _logErc20Metadata(string memory label, address token) internal view {
        (bool okName, bytes memory nameData) = token.staticcall(abi.encodeWithSignature("name()"));
        (bool okSymbol, bytes memory symbolData) = token.staticcall(abi.encodeWithSignature("symbol()"));
        (bool okDecimals, bytes memory decimalsData) = token.staticcall(abi.encodeWithSignature("decimals()"));

        console2.log(label, token);
        if (okName) console2.log("  name:   ", abi.decode(nameData, (string)));
        if (okSymbol) console2.log("  symbol: ", abi.decode(symbolData, (string)));
        if (okDecimals) console2.log("  decimals:", uint256(uint8(abi.decode(decimalsData, (uint8)))));
    }

    function run() external {
        address indexToken_ = vm.envAddress("INDEX_TOKEN");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address finalizer_  = vm.envOr("FINALIZER", deployer);
        uint256 initialPrice = vm.envOr("INITIAL_PRICE", uint256(0));

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
        address underlyingTokenFromEnv = vm.envOr("UNDERLYING_TOKEN", address(0));
        address underlyingToken_ = underlyingTokenFromEnv;
        if (underlyingToken_ == address(0)) {
            underlyingToken_ = address(new MockPlainERC20());
            console2.log("MockPlainERC20 deployed:", underlyingToken_);
        } else {
            console2.log("MockPlainERC20 provided:", underlyingToken_);
        }

        router = new FHERouter(
            address(positionManager),
            address(vault),
            address(orderManager),
            address(fundingManager),
            fheToken,
            indexToken_,
            underlyingToken_
        );

        vault.setUnderlyingToken(underlyingToken_);

        vault.setPositionManager(address(positionManager));
        vault.setRouter(address(router));
        positionManager.setRouter(address(router));
        positionManager.setFHEFundingManager(address(fundingManager));
        fundingManager.setPositionManager(address(positionManager));

        positionManager.setFheRouter(address(router));
        positionManager.setLiquidationManager(address(liquidationManager));
        positionManager.setFinalizer(finalizer_);

        orderManager.setRouter(address(router));

        // Initialize FHE funding state for the index token so updateFunding()
        // doesn't encounter zero handles on the first trade.
        fundingManager.initializeToken(indexToken_);

        // Optional bootstrap oracle price to avoid "price not set" on first flow tests.
        if (initialPrice > 0) {
            oracle.setPrice(indexToken_, initialPrice);
        }

        vm.stopBroadcast();

        console2.log("\n=== ShadeSpot FHE deployment complete ===");
        _logErc20Metadata("FHE collateral:", fheToken);
        _logErc20Metadata("Plain underlying:", underlyingToken_);
        console2.log("PriceOracle:         ", address(oracle));
        console2.log("FHEFundingManager:   ", address(fundingManager));
        console2.log("FHEVault:            ", address(vault));
        console2.log("PositionManager:     ", address(positionManager));
        console2.log("FHEOrderManager:     ", address(orderManager));
        console2.log("LiquidationManager:  ", address(liquidationManager));
        console2.log("FHERouter:           ", address(router));
        console2.log("Finalizer:           ", finalizer_);
        if (initialPrice > 0) {
            console2.log("Initial price set:   ", initialPrice);
        }
        console2.log("\nIndex token (ETH):   ", indexToken_);
    }
}
