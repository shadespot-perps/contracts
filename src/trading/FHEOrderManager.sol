// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/FHEFundingRateManager.sol";
import "../oracle/PriceOracle.sol";
import { FHE, euint64, euint128, ebool } from "cofhe-contracts/FHE.sol";

/**
 * @title OrderManager
 * @notice Manages encrypted limit and trigger orders.
 */
contract FHEOrderManager {

    struct Order {
        address  trader;
        address  token;
        euint64  collateral;
        euint64  leverage;
        euint128 triggerPrice;
        ebool    isLong;
        bool     isActive;
    }

    uint256 public nextOrderId;

    mapping(uint256 => Order) private orders;

    mapping(uint256 => ebool) private _pendingPriceCheck;

    PriceOracle        public oracle;
    

    address public router;
    address public owner;
    FHEFundingRateManager public fheFundingManager;

    event OrderCreated(
        uint256 indexed orderId,
        address indexed trader,
        address         token,
        bytes32         collateralHandle
    );  

    event OrderPriceCheckSubmitted(
        uint256 indexed orderId,
        bytes32         shouldExecHandle
    );

    event OrderExecuted(uint256 indexed orderId, address indexed trader);
    event OrderCancelled(uint256 indexed orderId);

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
        oracle            = PriceOracle(_oracle);
        fheFundingManager = FHEFundingRateManager(_fundingManager);
        owner             = _owner;
    }

    function setRouter(address _router) external onlyOwner {
        require(router == address(0), "router already set");
        router = _router;
    }

    /// @notice Returns order metadata for authorized callers.
    function getOrderMeta(uint256 orderId)
        external
        view
        returns (
            address trader,
            address token,
            euint64 collateral,
            euint64 leverage,
            ebool   isLong,
            bool    isActive
        )
    {
        Order storage o = orders[orderId];
        require(msg.sender == o.trader || msg.sender == router, "unauthorized");
        return (o.trader, o.token, o.collateral, o.leverage, o.isLong, o.isActive);
    }

    /// @notice Returns whether an order is active.
    function isOrderActive(uint256 orderId) external view returns (bool) {
        return orders[orderId].isActive;
    }

    /**
     * @notice Stores an encrypted limit order.
     * @param eCollateral Encrypted collateral.
     * @param eTriggerPrice Encrypted trigger price (euint128).
     */
    function createOrder(
        address  trader,
        address  token,
        euint64  eCollateral,
        euint64  eLeverage,
        euint128 eTriggerPrice,
        ebool    eIsLong
    ) external onlyRouter {
        uint256 orderId = nextOrderId;

        FHE.allow(eCollateral,   address(this));
        FHE.allow(eLeverage,     address(this));
        FHE.allow(eTriggerPrice, address(this));
        FHE.allow(eIsLong,       address(this));
        
        FHE.allow(eCollateral,   trader);
        FHE.allow(eLeverage,     trader);
        FHE.allow(eTriggerPrice, trader);
        FHE.allow(eIsLong,       trader);

        orders[orderId] = Order({
            trader:       trader,
            token:        token,
            collateral:   eCollateral,
            leverage:     eLeverage,
            triggerPrice: eTriggerPrice,
            isLong:       eIsLong,
            isActive:     true
        });

        emit OrderCreated(orderId, trader, token, euint64.unwrap(eCollateral));

        nextOrderId++;
    }

    function cancelOrder(uint256 orderId, address caller) external onlyRouter {
        Order storage order = orders[orderId];
        require(order.trader == caller, "not owner");
        require(order.isActive, "inactive");

        order.isActive = false;
        _pendingPriceCheck[orderId] = ebool.wrap(bytes32(0));

        emit OrderCancelled(orderId);
    }

    /**
     * @notice Phase 1 of execution. Computes encrypted trigger condition.
     * @param orderId Order to check.
     * @param oraclePrice Current oracle price.
     */
    function submitPriceCheck(uint256 orderId, uint256 oraclePrice)
        external
        onlyRouter
        returns (bytes32 shouldExecHandle)
    {
        Order storage order = orders[orderId];
        require(order.isActive, "inactive");

        euint128 eOraclePrice = FHE.asEuint128(oraclePrice);

        FHE.allowTransient(order.triggerPrice, address(this));
        FHE.allowTransient(order.isLong, address(this));

        ebool belowTrigger = FHE.lte(eOraclePrice, order.triggerPrice);
        ebool aboveTrigger = FHE.gte(eOraclePrice, order.triggerPrice);

        ebool shouldExec = FHE.select(order.isLong, belowTrigger, aboveTrigger);

        FHE.allow(shouldExec, address(this));

        _pendingPriceCheck[orderId] = shouldExec;

        shouldExecHandle = ebool.unwrap(shouldExec);
        emit OrderPriceCheckSubmitted(orderId, shouldExecHandle);
    }

    /**
     * @notice Phase 2 of execution. Verifies proof and returns order data.
     * @param orderId          Order to execute.
     * @param shouldExecPlain  Decrypted boolean from the Threshold Network.
     * @param shouldExecSig    Threshold Network signature for the shouldExec handle.
     */
    function executeOrder(
        uint256 orderId,
        bool    shouldExecPlain,
        bytes calldata shouldExecSig
    )
        external
        onlyRouter
        returns (
            address trader,
            address token,
            euint64 collateral,
            euint64 leverage,
            ebool   isLong
        )
    {
        Order storage order = orders[orderId];
        require(order.isActive, "inactive");

        ebool shouldExec = _pendingPriceCheck[orderId];
        require(ebool.unwrap(shouldExec) != bytes32(0), "price check not submitted");

        FHE.publishDecryptResult(shouldExec, shouldExecPlain, shouldExecSig);
        require(shouldExecPlain, "price not reached");
        fheFundingManager.updateFunding(order.token);

        order.isActive = false;
        _pendingPriceCheck[orderId] = ebool.wrap(bytes32(0));

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
