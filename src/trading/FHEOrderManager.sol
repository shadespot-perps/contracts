// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/FHEFundingRateManager.sol";
import "../oracle/PriceOracle.sol";
import { FHE, euint64, euint128, ebool } from "cofhe-contracts/FHE.sol";

/**
 * @title OrderManager
 * @notice Manages limit/trigger orders with fully encrypted collateral and trigger price.
 *
Privacy design:
 *   - triggerPrice is stored as euint128 received directly as a pre-encrypted
 *     InEuint128 from the user.
 *   - collateral is stored as euint64 received via FHERouter — raw values remain hidden.
 *     appears in calldata or storage.
 *   - 
 *     Execution uses a two-phase FHE comparison:
 *       Phase 1 — submitPriceCheck(orderId): computes ebool shouldExecute = FHE.lte/gte(eTrigger, ePrice)
 *                 and emits the handle for off-chain decryption.
 *       Phase 2 — executeOrder(orderId, shouldExecPlain, shouldExecSig): verifies
 *                 the Threshold Network proof and opens the position.
 *   - Events emit ciphertext handles (bytes32) securely.
 */
contract FHEOrderManager {

    struct Order {
        address  trader;
        address  token;
        euint64  collateral;  // encrypted — no plaintext in storage
        euint64  leverage;
        euint128 triggerPrice; // encrypted — not readable via public getter
        ebool    isLong;
        bool     isActive;
    }

    uint256 public nextOrderId;

    mapping(uint256 => Order) private orders;

    // Phase 1 of execution: encrypted price-check result.
    // Cleared on execution and cancellation.
    mapping(uint256 => ebool) private _pendingPriceCheck;

    PriceOracle        public oracle;
    

    address public router;
    address public owner;
    FHEFundingRateManager public fheFundingManager;

    event OrderCreated(
        uint256 indexed orderId,
        address indexed trader,
        address         token,
        bytes32         collateralHandle  // euint64 handle — trader-decryptable
        // triggerPrice intentionally omitted — handle not emitted to avoid correlation
    );

    event OrderPriceCheckSubmitted(
        uint256 indexed orderId,
        bytes32         shouldExecHandle  // ebool handle for off-chain decrypt
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

        owner        = _owner;
    }

    function setRouter(address _router) external onlyOwner {
        require(router == address(0), "router already set");
        router = _router;
    }

    /// @notice Returns order fields needed for refunds/checks.
    ///         Restricted to the order owner or the router — no public order book.
    ///         collateral is returned as euint64; callers may pass it directly to vault ops.
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

    /// @notice Check whether an order is active — safe for keepers without revealing trade details.
    function isOrderActive(uint256 orderId) external view returns (bool) {
        return orders[orderId].isActive;
    }

    // --------------------------------
    // CREATE LIMIT ORDER
    // --------------------------------

    /**
     * @notice Store an encrypted limit order. Both collateral and triggerPrice arrive
     *         already encrypted from the client via FHERouter — fully encrypted.
     * @param eCollateral  Encrypted collateral (euint64) — pre-authorised by router ACL.
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

        // Persist handles; allow this contract to operate on them in future txs.
        FHE.allow(eCollateral,   address(this));
        FHE.allow(eLeverage,     address(this));
        FHE.allow(eTriggerPrice, address(this));
        FHE.allow(eIsLong,       address(this));
        FHE.allow(eCollateral,   trader); // trader can verify their own collateral
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

    // --------------------------------
    // CANCEL ORDER
    // --------------------------------

    function cancelOrder(uint256 orderId, address caller) external onlyRouter {
        Order storage order = orders[orderId];
        require(order.trader == caller, "not owner");
        require(order.isActive, "inactive");

        order.isActive = false;
        _pendingPriceCheck[orderId] = ebool.wrap(bytes32(0));

        emit OrderCancelled(orderId);
    }

    // --------------------------------
    // SUBMIT PRICE CHECK  (Phase 1 of execution)
    // --------------------------------

    /**
     * @notice Phase 1 of execution — compute the encrypted trigger-price comparison and
     *         emit the handle for off-chain decryption by a keeper.
     *         After off-chain decrypt, the keeper calls executeOrder with the proof.
     * @param orderId    Order to check.
     * @param oraclePrice Current oracle price (oracle prices are natively public).
     */
    function submitPriceCheck(uint256 orderId, uint256 oraclePrice)
        external
        onlyRouter
        returns (bytes32 shouldExecHandle)
    {
        Order storage order = orders[orderId];
        require(order.isActive, "inactive");

        euint128 eOraclePrice = FHE.asEuint128(oraclePrice);

        // FHE.allowTransient so we can use the stored triggerPrice in this tx.
        FHE.allowTransient(order.triggerPrice, address(this));
        FHE.allowTransient(order.isLong, address(this));

        // long (buy limit): execute when oracle <= trigger
        ebool belowTrigger = FHE.lte(eOraclePrice, order.triggerPrice);
        // short (sell limit): execute when oracle >= trigger
        ebool aboveTrigger = FHE.gte(eOraclePrice, order.triggerPrice);
        
        // Dynamically select target bound completely blindly!
        ebool shouldExec = FHE.select(order.isLong, belowTrigger, aboveTrigger);

        FHE.allow(shouldExec, address(this));

        _pendingPriceCheck[orderId] = shouldExec;

        shouldExecHandle = ebool.unwrap(shouldExec);
        emit OrderPriceCheckSubmitted(orderId, shouldExecHandle);
    }

    // --------------------------------
    // EXECUTE ORDER (Phase 2 — called by Router / keepers)
    // --------------------------------

    /**
     * @notice Phase 2 of execution — verify the Threshold Network proof for the price
     *         check and open the position if the condition was met.
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

        // Verify Threshold Network proof — reverts if signature is invalid.
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
