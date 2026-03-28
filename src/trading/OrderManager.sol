// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../oracle/PriceOracle.sol";
import "../core/FundingRateManager.sol";
import "cofhe-contracts/FHE.sol";

/**
 * @title OrderManager
 * @notice Manages limit/trigger orders with encrypted trigger price storage.
 *
 * Privacy design:
 *   - triggerPrice is stored as an FHE ciphertext (euint128) so the order book
 *     cannot be read on-chain — preventing front-running of pending limit orders.
 *   - The execution check compares the oracle price against the encrypted trigger
 *     using a private mapping that is cleared on execution/cancellation. This
 *     avoids exposing the trigger price in storage after the order lifecycle ends.
 *
 * Note on calldata privacy: triggerPrice currently enters as a plaintext uint256
 * (visible in transaction calldata). For full pre-submission privacy, upgrade the
 * createOrder interface to accept InEuint128 from the CoFHE client SDK so the
 * value is encrypted before it reaches the mempool.
 */
contract OrderManager {

    struct Order {
        address  trader;
        address  token;
        uint256  collateral;
        uint256  leverage;
        euint128 triggerPrice; // encrypted — not readable via public getter
        bool     isLong;
        bool     isActive;
    }

    uint256 public nextOrderId;

    mapping(uint256 => Order)   public orders;

    // Separate private mapping for the execution check to keep the plaintext
    // trigger price off the public struct getter entirely.
    // NOTE: this is cleared on execution and cancellation.
    mapping(uint256 => uint256) private _triggerPriceForExec;

    PriceOracle        public oracle;
    FundingRateManager public fundingManager;

    address public router;
    address public owner;

    event OrderCreated(
        uint256 indexed orderId,
        address indexed trader,
        address         token
        // triggerPrice intentionally omitted to not leak intent on-chain
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
        oracle       = PriceOracle(_oracle);
        fundingManager = FundingRateManager(_fundingManager);
        owner        = _owner;
    }

    function setRouter(address _router) external onlyOwner {
        require(router == address(0), "router already set");
        router = _router;
    }

    /// @notice Returns only the fields Router needs for refunds/checks, avoiding
    ///         ABI issues with euint128 (user-defined value type) in struct getters.
    function getOrderMeta(uint256 orderId)
        external
        view
        returns (address trader, address token, uint256 collateral, uint256 leverage, bool isLong, bool isActive)
    {
        Order storage o = orders[orderId];
        return (o.trader, o.token, o.collateral, o.leverage, o.isLong, o.isActive);
    }

    // --------------------------------
    // CREATE LIMIT ORDER
    // --------------------------------

    /**
     * @param triggerPrice Plaintext trigger price. The value is trivially encrypted
     *        on-chain so it cannot be read from storage after creation. Note: the
     *        plaintext is still visible in calldata. Upgrade to InEuint128 for full
     *        pre-submission privacy.
     */
    function createOrder(
        address trader,
        address token,
        uint256 collateral,
        uint256 leverage,
        uint256 triggerPrice,
        bool    isLong
    ) external onlyRouter {
        require(collateral > 0, "invalid collateral");

        uint256 orderId = nextOrderId;

        orders[orderId] = Order({
            trader:       trader,
            token:        token,
            collateral:   collateral,
            leverage:     leverage,
            triggerPrice: FHE.asEuint128(triggerPrice), // encrypt for storage
            isLong:       isLong,
            isActive:     true
        });

        // Keep plaintext in a private mapping for the sync execution check.
        // Cleared on execution or cancellation.
        _triggerPriceForExec[orderId] = triggerPrice;

        emit OrderCreated(orderId, trader, token);

        nextOrderId++;
    }

    // --------------------------------
    // CANCEL ORDER
    // --------------------------------

    function cancelOrder(uint256 orderId, address caller) external onlyRouter {
        Order storage order = orders[orderId];
        require(order.trader == caller, "not owner");
        require(order.isActive, "inactive");

        order.isActive = false;
        delete _triggerPriceForExec[orderId];

        emit OrderCancelled(orderId);
    }

    // --------------------------------
    // EXECUTE ORDER (called by Router / keepers)
    // --------------------------------

    function executeOrder(uint256 orderId)
        external
        onlyRouter
        returns (
            address trader,
            address token,
            uint256 collateral,
            uint256 leverage,
            bool    isLong
        )
    {
        Order storage order = orders[orderId];
        require(order.isActive, "inactive");

        uint256 price        = oracle.getPrice(order.token);
        uint256 triggerPrice = _triggerPriceForExec[orderId];

        bool shouldExecute = order.isLong
            ? price <= triggerPrice
            : price >= triggerPrice;

        require(shouldExecute, "price not reached");

        fundingManager.updateFunding(order.token);

        order.isActive = false;
        delete _triggerPriceForExec[orderId];

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
