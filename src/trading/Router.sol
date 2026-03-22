// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/PositionManager.sol";
import "../core/Vault.sol";
import "../core/FundingRateManager.sol";
import "./OrderManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Router {

    PositionManager public positionManager;
    Vault public vault;
    OrderManager public orderManager;
    FundingRateManager public fundingManager;

    IERC20 public collateralToken;

    event OpenPosition(
        address indexed trader,
        address token,
        uint256 collateral,
        uint256 leverage,
        bool isLong
    );

    event ClosePosition(
        address indexed trader,
        address token,
        bool isLong
    );

    event OrderCreated(
        address indexed trader,
        address token,
        uint256 triggerPrice
    );

    event OrderExecuted(uint256 orderId);

    event AddLiquidity(address indexed user, uint256 amount);
    event RemoveLiquidity(address indexed user, uint256 amount);

    constructor(
        address _positionManager,
        address _vault,
        address _orderManager,
        address _fundingManager,
        address _collateralToken
    ) {
        positionManager = PositionManager(_positionManager);
        vault = Vault(_vault);
        orderManager = OrderManager(_orderManager);
        fundingManager = FundingRateManager(_fundingManager);
        collateralToken = IERC20(_collateralToken);
    }

    // -------------------------------------------------
    // MARKET ORDER (OPEN POSITION)
    // -------------------------------------------------

    function openPosition(
        address token,
        uint256 collateral,
        uint256 leverage,
        bool isLong
    ) external {

        require(collateral > 0, "invalid collateral");

        // update funding before opening
        fundingManager.updateFunding(token);

        // transfer collateral
        collateralToken.transferFrom(
            msg.sender,
            address(vault),
            collateral
        );

        positionManager.openPosition(
            msg.sender,
            token,
            collateral,
            leverage,
            isLong
        );

        emit OpenPosition(
            msg.sender,
            token,
            collateral,
            leverage,
            isLong
        );
    }

    // -------------------------------------------------
    // CLOSE POSITION
    // -------------------------------------------------

    function closePosition(
        address token,
        bool isLong
    ) external {

        // update funding before closing
        fundingManager.updateFunding(token);

        positionManager.closePosition(
            msg.sender,
            token,
            isLong
        );

        emit ClosePosition(msg.sender, token, isLong);
    }

    // -------------------------------------------------
    // CREATE LIMIT ORDER
    // -------------------------------------------------

    function createOrder(
        address token,
        uint256 collateral,
        uint256 leverage,
        uint256 triggerPrice,
        bool isLong
    ) external {

        require(collateral > 0, "invalid collateral");

        collateralToken.transferFrom(
            msg.sender,
            address(vault),
            collateral
        );

        orderManager.createOrder(
            msg.sender,
            token,
            collateral,
            leverage,
            triggerPrice,
            isLong
        );

        emit OrderCreated(msg.sender, token, triggerPrice);
    }

    // -------------------------------------------------
    // CANCEL ORDER
    // -------------------------------------------------

    function cancelOrder(uint256 orderId) external {
        (address trader, , uint256 collateral, , , , ) = orderManager.orders(orderId);
        orderManager.cancelOrder(orderId, msg.sender);
        vault.refundCollateral(trader, collateral);
    }

    // -------------------------------------------------
    // EXECUTE ORDER (KEEPERS)
    // -------------------------------------------------

    function executeOrder(uint256 orderId) external {

        (
            address trader,
            address token,
            uint256 collateral,
            uint256 leverage,
            bool isLong
        ) = orderManager.executeOrder(orderId);

        // update funding before executing
        fundingManager.updateFunding(token);

        positionManager.openPosition(
            trader,
            token,
            collateral,
            leverage,
            isLong
        );

        emit OrderExecuted(orderId);
    }

    // -------------------------------------------------
    // LIQUIDITY FUNCTIONS
    // -------------------------------------------------

    function addLiquidity(uint256 amount) external {

        collateralToken.transferFrom(
            msg.sender,
            address(vault),
            amount
        );

        vault.deposit(amount);

        emit AddLiquidity(msg.sender, amount);
    }

    function removeLiquidity(uint256 amount) external {

        vault.withdraw(amount);

        emit RemoveLiquidity(msg.sender, amount);
    }
}