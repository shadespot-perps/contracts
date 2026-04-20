// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../core/FHEFundingRateManager.sol";
import "../core/PositionManager.sol";
import "../core/FHEVault.sol";
import "./FHEOrderManager.sol";
import "../tokens/IEncryptedERC20.sol";
import { FHE, euint64, euint128, ebool, InEbool, InEuint64, InEuint128 } from "cofhe-contracts/FHE.sol";

/**
 * @title FHERouter
 * @notice Protocol entry point for encrypted trading and liquidity flows.
 */
contract FHERouter {
    struct PendingOpenRequest {
        bytes32 collateralHandle;
        bytes32 leverageHandle;
        bytes32 isLongHandle;
        bool exists;
    }

    PositionManager    public positionManager;
    FHEVault           public vault;
    FHEOrderManager    public orderManager;
    

    IEncryptedERC20 public collateralToken;

    /// @notice Only supported index token for this router.
    address public immutable indexToken;

    address public owner;
    FHEFundingRateManager public fheFundingManager;
    mapping(address => PendingOpenRequest) public pendingOpenRequests;

    event OpenPosition(bytes32 indexed positionKey, address indexed trader);
    event ClosePosition(bytes32 indexed positionKey, address indexed trader);

    event OrderCreated(
        address indexed trader,
        address         token
    );

    event OrderExecuted(uint256 orderId);

    /// @notice `amountHandle` is a CoFHE ciphertext handle.
    event AddLiquidity(address indexed user, bytes32 amountHandle);
    /// @notice `amountHandle` is the encrypted withdrawal amount handle.
    event RemoveLiquidity(address indexed user, bytes32 amountHandle);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(
        address _positionManager,
        address _vault,
        address _orderManager,
        address _fheFunding,
        address _collateralToken,
        address _indexToken
    ) {
        require(_indexToken != address(0), "invalid index token");
        positionManager = PositionManager(_positionManager);
        vault           = FHEVault(_vault);
        orderManager    = FHEOrderManager(_orderManager);
        fheFundingManager = FHEFundingRateManager(_fheFunding);
        collateralToken = IEncryptedERC20(_collateralToken);
        indexToken      = _indexToken;
        owner           = msg.sender;
    }

    /**
     * @notice Phase 1 of opening a position. Submits the encrypted liquidity check.
     * @param token         Index token; must equal `indexToken`.
     * @param encCollateral Encrypted collateral (InEuint64).
     * @param encLeverage   Encrypted leverage (InEuint64).
     * @param encIsLong     Encrypted direction (InEbool).
     */
    function submitOpenPositionCheck(
        address    token,
        InEuint64  calldata encCollateral,
        InEuint64  calldata encLeverage,
        InEbool    calldata encIsLong
    ) public {
        require(token == indexToken, "unsupported index token");

        fheFundingManager.updateFunding(token);

        euint64 eCollateral = FHE.asEuint64(encCollateral);
        euint64 eLeverage = FHE.asEuint64(encLeverage);
        ebool eIsLong = FHE.asEbool(encIsLong);
        euint64 eSize = FHE.mul(eCollateral, eLeverage);
        FHE.allow(eSize, address(vault));

        pendingOpenRequests[msg.sender] = PendingOpenRequest({
            collateralHandle: euint64.unwrap(eCollateral),
            leverageHandle: euint64.unwrap(eLeverage),
            isLongHandle: ebool.unwrap(eIsLong),
            exists: true
        });

        vault.submitReserveLiquidityCheck(msg.sender, eSize);
    }

    /**
     * @notice Phase 2 of opening a position. Verifies proof and opens the position.
     * @param token         Index token; must equal `indexToken`.
     * @param encCollateral Encrypted collateral that matches the phase-1 request.
     * @param encLeverage   Encrypted leverage.
     * @param encIsLong     Encrypted direction.
     * @param hasLiqPlain   Decrypted liquidity-check boolean from the Threshold Network.
     * @param hasLiqSig     Threshold Network signature for the hasLiq handle.
     * @dev Caller must grant operator access with `setOperator`.
     */
    function finalizeOpenPosition(
        address    token,
        InEuint64  calldata encCollateral,
        InEuint64  calldata encLeverage,
        InEbool    calldata encIsLong,
        bool       hasLiqPlain,
        bytes calldata hasLiqSig
    ) public returns (bytes32 positionId) {
        require(token == indexToken, "unsupported index token");

        fheFundingManager.updateFunding(token);


        vault.storeReserveLiquidityProof(msg.sender, hasLiqPlain, hasLiqSig);

        euint64 eCollateral = FHE.asEuint64(encCollateral);
        euint64 eLeverage = FHE.asEuint64(encLeverage);
        ebool eIsLong = FHE.asEbool(encIsLong);

        PendingOpenRequest memory pending = pendingOpenRequests[msg.sender];
        require(pending.exists, "open check not submitted");
        require(pending.collateralHandle == euint64.unwrap(eCollateral), "collateral mismatch");
        require(pending.leverageHandle == euint64.unwrap(eLeverage), "leverage mismatch");
        require(pending.isLongHandle == ebool.unwrap(eIsLong), "direction mismatch");
        delete pendingOpenRequests[msg.sender];

        FHE.allow(eCollateral, address(collateralToken));
        FHE.allow(eCollateral, address(positionManager));
        FHE.allow(eCollateral, msg.sender);

        collateralToken.confidentialTransferFrom(msg.sender, address(vault), eCollateral);

        positionId = positionManager.openPositionFHE(msg.sender, token, eCollateral, eLeverage, eIsLong);

        emit OpenPosition(positionId, msg.sender);
    }

    function requestClosePosition(bytes32 positionId) public {
        positionManager.requestClosePosition(msg.sender, positionId);
        emit ClosePosition(positionId, msg.sender);
    }

    /**
     * @notice Create a limit/trigger order using FHE token collateral.
     *         Both collateral and triggerPrice are encrypted client-side — the
     *         values remain strictly encrypted.
     * @dev Caller must have granted this router operator status on the FHE token.
     */
    function createEncryptedOrder(
        address    token,
        InEuint64  calldata encCollateral,
        InEuint64  calldata encLeverage,
        InEuint128 calldata encTriggerPrice,
        InEbool    calldata encIsLong
    ) public {
        require(token == indexToken, "unsupported index token");

        fheFundingManager.updateFunding(token);

        euint64  eCollateral   = FHE.asEuint64(encCollateral);
        euint128 eTriggerPrice = FHE.asEuint128(encTriggerPrice);

        FHE.allow(eCollateral,   address(collateralToken));
        FHE.allow(eCollateral,   address(orderManager));
        FHE.allow(eCollateral,   address(vault));
        FHE.allow(eCollateral,   msg.sender);
        FHE.allow(eTriggerPrice, address(orderManager));

        collateralToken.confidentialTransferFrom(msg.sender, address(vault), eCollateral);

        euint64  eLeverage     = FHE.asEuint64(encLeverage);
        ebool    eIsLong       = FHE.asEbool(encIsLong);

        orderManager.createOrder(msg.sender, token, eCollateral, eLeverage, eTriggerPrice, eIsLong);

        emit OrderCreated(msg.sender, token);
    }

    function cancelEncryptedOrder(uint256 orderId) public {
        (address trader, , euint64 eCollateral, , , ) = orderManager.getOrderMeta(orderId);
        orderManager.cancelOrder(orderId, msg.sender);
        FHE.allow(eCollateral, address(vault));
        vault.refundCollateral(trader, eCollateral);
    }

    /**
     * @notice Phase 1 of order execution. Submits liquidity and price checks.
     * @param orderId Order to evaluate.
     * @return hasLiqHandle    Handle for the liquidity-sufficient boolean.
     * @return shouldExecHandle Handle for the price-condition boolean.
     */
    function submitOrderExecutionChecks(uint256 orderId)
        public
        returns (bytes32 hasLiqHandle, bytes32 shouldExecHandle)
    {
        (
            address trader,
            address token,
            euint64 eCollateral,
            euint64 eLeverage,
            ,
        ) = orderManager.getOrderMeta(orderId);
        require(token == indexToken, "unsupported index token");

        fheFundingManager.updateFunding(token);

        euint64 eSize = FHE.mul(eCollateral, eLeverage);
        FHE.allow(eSize, address(vault));
        vault.submitReserveLiquidityCheck(trader, eSize);

        uint256 oraclePrice = _getOraclePrice(token);
        shouldExecHandle = orderManager.submitPriceCheck(orderId, oraclePrice);

        ( , hasLiqHandle) = _getPendingLiqHandle(trader);
    }

    /**
     * @notice Phase 2 of order execution. Verifies proofs and opens the position.
     * @param orderId          Order to finalize.
     * @param shouldExecPlain  Decrypted price-condition boolean.
     * @param shouldExecSig    Threshold Network signature for shouldExec.
     * @param hasLiqPlain      Decrypted liquidity-sufficient boolean.
     * @param hasLiqSig        Threshold Network signature for hasLiq.
     */
    function finalizeOrderExecution(
        uint256 orderId,
        bool    shouldExecPlain,
        bytes calldata shouldExecSig,
        bool    hasLiqPlain,
        bytes calldata hasLiqSig
    ) public {
        (
            address trader,
            address token,
            euint64 eCollateral,
            euint64 eLeverage,
            ebool eIsLong
        ) = orderManager.executeOrder(orderId, shouldExecPlain, shouldExecSig);


        vault.storeReserveLiquidityProof(trader, hasLiqPlain, hasLiqSig);

        FHE.allow(eCollateral, address(positionManager));

        positionManager.openPositionFHE(trader, token, eCollateral, eLeverage, eIsLong);

        emit OrderExecuted(orderId);
    }

    /**
     * @notice Adds encrypted collateral as liquidity.
     * @dev Caller must grant operator access with `setOperator`.
     */
    function addLiquidity(InEuint64 calldata encAmount) external {
        euint64 eAmount = FHE.asEuint64(encAmount);
        FHE.allow(eAmount, address(collateralToken));
        FHE.allow(eAmount, address(vault));
        FHE.allow(eAmount, msg.sender);

        collateralToken.confidentialTransferFrom(msg.sender, address(vault), eAmount);
        vault.deposit(msg.sender, eAmount);

        emit AddLiquidity(msg.sender, euint64.unwrap(eAmount));
    }

    /**
     * @notice Phase 1 of liquidity removal. Submits encrypted withdrawal checks.
     * @param shares Standard share amount to redeem.
     */
    function submitLiquidityWithdrawalCheck(uint256 shares) public {
        vault.submitWithdrawCheck(msg.sender, shares);
    }

    /**
     * @notice Phase 2 of liquidity removal. Verifies proofs and executes withdrawal.
     * @param shares     Must match the value passed to submitLiquidityWithdrawalCheck.
     * @param balPlain   Decrypted balance-check boolean.
     * @param balSig     Threshold Network signature for hasBal.
     * @param liqPlain   Decrypted liquidity-check boolean.
     * @param liqSig     Threshold Network signature for hasLiq.
     */
    function finalizeLiquidityWithdrawal(
        uint256 shares,
        bool    balPlain,
        bytes calldata balSig,
        bool    liqPlain,
        bytes calldata liqSig
    ) public {
        bytes32 amountHandle = vault.withdrawWithProof(
            msg.sender, shares, balPlain, balSig, liqPlain, liqSig
        );
        emit RemoveLiquidity(msg.sender, amountHandle);
    }

    // Backward-compatible aliases for existing integrations.
    function submitDecryptTaskForOpen(
        address    token,
        InEuint64  calldata encCollateral,
        InEuint64  calldata encLeverage,
        InEbool    calldata encIsLong
    ) external {
        submitOpenPositionCheck(token, encCollateral, encLeverage, encIsLong);
    }

    function openPosition(
        address    token,
        InEuint64  calldata encCollateral,
        InEuint64  calldata encLeverage,
        InEbool    calldata encIsLong,
        bool       hasLiqPlain,
        bytes calldata hasLiqSig
    ) external returns (bytes32 positionId) {
        return finalizeOpenPosition(token, encCollateral, encLeverage, encIsLong, hasLiqPlain, hasLiqSig);
    }

    function closePosition(bytes32 positionId) external {
        requestClosePosition(positionId);
    }

    function createOrder(
        address    token,
        InEuint64  calldata encCollateral,
        InEuint64  calldata encLeverage,
        InEuint128 calldata encTriggerPrice,
        InEbool    calldata encIsLong
    ) external {
        createEncryptedOrder(token, encCollateral, encLeverage, encTriggerPrice, encIsLong);
    }

    function cancelOrder(uint256 orderId) external {
        cancelEncryptedOrder(orderId);
    }

    function submitDecryptTaskForOrder(uint256 orderId)
        external
        returns (bytes32 hasLiqHandle, bytes32 shouldExecHandle)
    {
        return submitOrderExecutionChecks(orderId);
    }

    function executeOrder(
        uint256 orderId,
        bool    shouldExecPlain,
        bytes calldata shouldExecSig,
        bool    hasLiqPlain,
        bytes calldata hasLiqSig
    ) external {
        finalizeOrderExecution(orderId, shouldExecPlain, shouldExecSig, hasLiqPlain, hasLiqSig);
    }

    function submitWithdrawCheck(uint256 shares) external {
        submitLiquidityWithdrawalCheck(shares);
    }

    function removeLiquidity(
        uint256 shares,
        bool    balPlain,
        bytes calldata balSig,
        bool    liqPlain,
        bytes calldata liqSig
    ) external {
        finalizeLiquidityWithdrawal(shares, balPlain, balSig, liqPlain, liqSig);
    }

    function _getOraclePrice(address token) internal view returns (uint256) {
        return positionManager.oracle().getPrice(token);
    }

    /**
     * @notice Returns the pending liquidity-check handle for a trader.
     */
    function _getPendingLiqHandle(address trader)
        internal
        view
        returns (ebool hasLiq, bytes32 hasLiqHandle)
    {
        (hasLiq, ) = vault.pendingLiqCheck(trader);
        hasLiqHandle = ebool.unwrap(hasLiq);
    }
}
