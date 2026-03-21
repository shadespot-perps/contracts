// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../oracle/PriceOracle.sol";
import "../core/FundingRateManager.sol";

contract OrderManager {

    struct Order {
        address trader;
        address token;
        uint256 collateral;
        uint256 leverage;
        uint256 triggerPrice;
        bool isLong;
        bool isActive;
    }

    uint256 public nextOrderId;

    mapping(uint256 => Order) public orders;

    PriceOracle public oracle;
    FundingRateManager public fundingManager;

    address public router;
    address public owner;

    event OrderCreated(
        uint256 orderId,
        address trader,
        address token,
        uint256 triggerPrice
    );

    event OrderExecuted(
        uint256 orderId,
        address trader
    );

    event OrderCancelled(
        uint256 orderId
    );

    modifier onlyRouter() {
        require(msg.sender == router, "only router");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    constructor(
        address _oracle,
        address _fundingManager,
        address _owner
    ) {
        oracle = PriceOracle(_oracle);
        fundingManager = FundingRateManager(_fundingManager);
        owner = _owner;
      }

    // --------------------------------
    // CREATE LIMIT ORDER
    // --------------------------------


  function setRouter(address _router) external onlyOwner {
    require(router == address(0), "router already set");
    router = _router;
}
    function createOrder(
        address token,
        uint256 collateral,
        uint256 leverage,
        uint256 triggerPrice,
        bool isLong
    ) external onlyRouter{

        require(collateral > 0, "invalid collateral");

        orders[nextOrderId] = Order({
            trader: msg.sender,
            token: token,
            collateral: collateral,
            leverage: leverage,
            triggerPrice: triggerPrice,
            isLong: isLong,
            isActive: true
        });

        emit OrderCreated(
            nextOrderId,
            msg.sender,
            token,
            triggerPrice
        );

        nextOrderId++;
    }

    // --------------------------------
    // CANCEL ORDER
    // --------------------------------

    function cancelOrder(uint256 orderId) external onlyRouter{

        Order storage order = orders[orderId];

        require(order.trader == msg.sender, "not owner");
        require(order.isActive, "inactive");

        order.isActive = false;

        emit OrderCancelled(orderId);
    }

    // --------------------------------
    // EXECUTE ORDER
    // --------------------------------
    // Called by Router
    // Funding updated before execution
    // --------------------------------

    function executeOrder(uint256 orderId)
        external
        onlyRouter
        returns (
            address trader,
            address token,
            uint256 collateral,
            uint256 leverage,
            bool isLong
        )
    {

        Order storage order = orders[orderId];

        require(order.isActive, "inactive");

        uint256 price = oracle.getPrice(order.token);

        bool shouldExecute;

        if (order.isLong) {
            shouldExecute = price <= order.triggerPrice;
        } else {
            shouldExecute = price >= order.triggerPrice;
        }

        require(shouldExecute, "price not reached");

        // 🔹 Update funding before opening position
        fundingManager.updateFunding(order.token);

        order.isActive = false;

        emit OrderExecuted(orderId, order.trader);

        return (
            order.trader,
            order.token,
            order.collateral,
            order.leverage,
            order.isLong
        );
    }
}