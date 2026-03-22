// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/PositionManager.sol";
import "../oracle/PriceOracle.sol";
import "../core/Vault.sol";
import "../core/FundingRateManager.sol";

contract LiquidationManager {

    PositionManager public positionManager;
    PriceOracle public oracle;
    Vault public vault;
    FundingRateManager public fundingManager;

    uint256 public constant LIQUIDATION_BONUS = 5; // 5%

    event LiquidationExecuted(
        address indexed trader,
        address indexed liquidator,
        address token,
        uint256 reward
    );

    constructor(
        address _positionManager,
        address _oracle,
        address _vault,
        address _fundingManager
    ) {
        positionManager = PositionManager(_positionManager);
        oracle = PriceOracle(_oracle);
        vault = Vault(_vault);
        fundingManager = FundingRateManager(_fundingManager);
    }

    // ------------------------------------------------
    // CHECK IF POSITION IS LIQUIDATABLE
    // ------------------------------------------------

    function isLiquidatable(
        address trader,
        address token,
        bool isLong
    ) public view returns (bool) {

        bytes32 key = positionManager.getPositionKey(trader, token, isLong);

        PositionManager.Position memory position =
            positionManager.getPosition(key);

        if (position.size == 0) {
            return false;
        }

        uint256 price = oracle.getPrice(token);

        int256 pnl = positionManager.calculatePnL(position, price);

        // funding adjustment
        int256 fundingFee = positionManager.calculateFundingFee(position);

        pnl -= fundingFee;

        if (pnl >= 0) {
            return false;
        }

        uint256 loss = uint256(-pnl);

        return loss >= (position.collateral * 80) / 100;
    }

    // ------------------------------------------------
    // LIQUIDATE POSITION
    // ------------------------------------------------

    function liquidate(
        address trader,
        address token,
        bool isLong
    ) external {

        require(
            isLiquidatable(trader, token, isLong),
            "position not liquidatable"
        );

        // update funding before liquidation
        fundingManager.updateFunding(token);

        bytes32 key = positionManager.getPositionKey(trader, token, isLong);

        PositionManager.Position memory position =
            positionManager.getPosition(key);

        uint256 reward =
            (position.collateral * LIQUIDATION_BONUS) / 100;

        // close position in position manager (handles liquidator reward internally)
        positionManager.liquidate(trader, token, isLong);

        emit LiquidationExecuted(
            trader,
            msg.sender,
            token,
            reward
        );
    }
}