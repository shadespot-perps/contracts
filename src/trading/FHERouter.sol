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
 * @notice ShadeSpot protocol entry point — collateral is a Fhenix FHERC20 token.
 *
* Open-position flow (three-phase):
 *   1. submitDecryptTaskForOpen(token, encCollateral, leverage)
 *      — computes FHE liquidity check; emits handle for off-chain decrypt.
 *   2. Off-chain: decrypt handle → (hasLiqPlain, hasLiqSig) via CoFHE SDK.
 *   3. openPosition(token, encCollateral, leverage, isLong, hasLiqPlain, hasLiqSig)
 *      — verifies proof, moves collateral, opens position.
 *
Remove-liquidity flow (two-phase):
 *   1. submitWithdrawCheck(shares)      — computes FHE checks; emits handles.
 *   2. Off-chain: decrypt handles.
 *   3. removeLiquidity(shares, balPlain, balSig, liqPlain, liqSig)
 *      — verifies proofs, executes encrypted transfer.
 *
Limit-order execution flow (four-phase, keeper):
 *   1. submitDecryptTaskForOrder(orderId) — submits BOTH liquidity and price checks; emits handles.
 *   2. Off-chain: decrypt both handles.
 *   3. storeOrderLiquidityProof(orderId, hasLiqPlain, hasLiqSig) — verifies liq proof.
 *   4. executeOrder(orderId, shouldExecPlain, shouldExecSig, hasLiqPlain, hasLiqSig) — opens position.
 */
contract FHERouter {

    PositionManager    public positionManager;
    FHEVault           public vault;
    FHEOrderManager    public orderManager;
    

    IEncryptedERC20 public collateralToken;

    /// @notice The only token that can be used as a trade (index) token in this pool.
    address public immutable indexToken;

    address public owner;
    FHEFundingRateManager public fheFundingManager;
    /// @notice ETH fee required for each trading action (open, close, order, liquidate).
    uint256 public actionFee;
    uint256 public collectedFees;

    // positionKey lets the frontend correlate with PositionManager events.
    // No trade parameters emitted — details are in the encrypted PositionOpened event.
    event OpenPosition(bytes32 indexed positionKey, address indexed trader);
    event ClosePosition(bytes32 indexed positionKey, address indexed trader);

    event OrderCreated(
        address indexed trader,
        address         token
    );

    event OrderExecuted(uint256 orderId);

    /// @notice amount field is a ciphertext handle (euint64.unwrap) — decrypt via CoFHE SDK.
    event AddLiquidity(address indexed user, bytes32 amountHandle);
    /// @notice amount field is the ciphertext handle of the payout — decrypt via CoFHE SDK.
    event RemoveLiquidity(address indexed user, bytes32 amountHandle);

    event ActionFeeSet(uint256 newFee);
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier requireFee() {
        require(msg.value >= actionFee, "Insufficient ETH fee");
        collectedFees += msg.value;
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

    function setActionFee(uint256 _fee) external onlyOwner {
        actionFee = _fee;
        emit ActionFeeSet(_fee);
    }

    function withdrawFees(address payable recipient) external onlyOwner {
        uint256 amount = collectedFees;
        collectedFees = 0;
        (bool ok, ) = recipient.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit FeesWithdrawn(recipient, amount);
    }

    // -------------------------------------------------
    // MARKET ORDER (OPEN POSITION)
    // -------------------------------------------------

    /**
     * @notice Phase 1 — submit the encrypted liquidity-check task so the CoFHE network
     *         can decrypt the result. Call this once, wait for the off-chain decrypt
     *         (~15–30 s on live CoFHE networks), then call openPosition with the proof.
 *
@param token         Index token (must equal indexToken).
     * @param encCollateral Encrypted collateral (InEuint64).
     * @param encLeverage   Encrypted leverage (InEuint64).
     * @param encIsLong     Encrypted direction (InEbool).
     */
    function submitDecryptTaskForOpen(
        address    token,
        InEuint64  calldata encCollateral,
        InEuint64  calldata encLeverage,
        InEbool    calldata encIsLong
    ) external {
        require(token == indexToken, "unsupported index token");

        fheFundingManager.updateFunding(token);

        // Unwrap the user-encrypted collateral into a usable euint64 handle.
        euint64 eCollateral = FHE.asEuint64(encCollateral);
        // Compute encrypted size = collateral * leverage (stays in FHE domain).
        euint64 eLeverage = FHE.asEuint64(encLeverage);
        euint64 eSize = FHE.mul(eCollateral, eLeverage);
        FHE.allow(eSize, address(vault));

        vault.submitReserveLiquidityCheck(msg.sender, eSize);
    }

    /**
     * @notice open a leveraged position using FHE token as collateral.
     *         Requires a prior submitDecryptTaskForOpen call and off-chain decrypt.
 *
@param token         Index token (must equal indexToken).
     * @param encCollateral Encrypted collateral — must be the same encrypted value used in
     *                      submitDecryptTaskForOpen (same ciphertext, re-submitted).
     * @param encLeverage   Encrypted leverage.
     * @param encIsLong     Encrypted direction.
     * @param hasLiqPlain   Decrypted liquidity-check boolean from the Threshold Network.
     * @param hasLiqSig     Threshold Network signature for the hasLiq handle.
 *
@dev Caller must have granted this router operator status on the FHE token:
     *      fheToken.setOperator(address(fheRouter), untilTimestamp)
     */
    function openPosition(
        address    token,
        InEuint64  calldata encCollateral,
        InEuint64  calldata encLeverage,
        InEbool    calldata encIsLong,
        bool       hasLiqPlain,
        bytes calldata hasLiqSig
    ) external payable requireFee returns (bytes32 positionId) {
        require(token == indexToken, "unsupported index token");

        fheFundingManager.updateFunding(token);


        // Verify the CoFHE decrypt proof before moving any funds.
        vault.storeReserveLiquidityProof(msg.sender, hasLiqPlain, hasLiqSig);

        // Unwrap encrypted collateral and allow relevant contracts to use the handle.
        euint64 eCollateral = FHE.asEuint64(encCollateral);
        FHE.allow(eCollateral, address(collateralToken));
        FHE.allow(eCollateral, address(positionManager));
        FHE.allow(eCollateral, msg.sender); // trader can verify their own collateral

        // Confidential transfer: router (operator) moves collateral from trader → vault.
        collateralToken.confidentialTransferFrom(msg.sender, address(vault), eCollateral);

        // Open position via the FHE-specific entry point — no plaintext collateral or direction.
        euint64 eLeverage = FHE.asEuint64(encLeverage);
        ebool eIsLong = FHE.asEbool(encIsLong);
        positionId = positionManager.openPositionFHE(msg.sender, token, eCollateral, eLeverage, eIsLong);

        emit OpenPosition(positionId, msg.sender);
    }

    // -------------------------------------------------
    // CLOSE POSITION
    // -------------------------------------------------

    function closePosition(bytes32 positionId) external payable requireFee {
        // We do respect the router's indexToken, but token is extracted inside PositionManager via positionId.
        positionManager.requestClosePositionFHE(msg.sender, positionId);
        emit ClosePosition(positionId, msg.sender);
    }

    // -------------------------------------------------
    // CREATE LIMIT ORDER
    // -------------------------------------------------

    /**
     * @notice Create a limit/trigger order using FHE token collateral.
     *         Both collateral and triggerPrice are encrypted client-side — the
     *         values remain strictly encrypted.
     * @dev Caller must have granted this router operator status on the FHE token.
     */
    function createOrder(
        address    token,
        InEuint64  calldata encCollateral,
        InEuint64  calldata encLeverage,
        InEuint128 calldata encTriggerPrice,
        InEbool    calldata encIsLong
    ) external payable requireFee {
        require(token == indexToken, "unsupported index token");

        fheFundingManager.updateFunding(token);

        // Unwrap encrypted inputs.
        euint64  eCollateral   = FHE.asEuint64(encCollateral);
        euint128 eTriggerPrice = FHE.asEuint128(encTriggerPrice);

        // Grant the order manager and vault access to the collateral handle.
        FHE.allow(eCollateral,   address(collateralToken));
        FHE.allow(eCollateral,   address(orderManager));
        FHE.allow(eCollateral,   address(vault));   // for refund on cancel
        FHE.allow(eCollateral,   msg.sender);        // trader self-decrypt
        FHE.allow(eTriggerPrice, address(orderManager));

        // Confidential transfer: collateral → vault.
        collateralToken.confidentialTransferFrom(msg.sender, address(vault), eCollateral);

        euint64  eLeverage     = FHE.asEuint64(encLeverage);
        ebool    eIsLong       = FHE.asEbool(encIsLong);

        // Persist encrypted order — no plaintext collateral, leverage, isLong, or triggerPrice stored.
        orderManager.createOrder(msg.sender, token, eCollateral, eLeverage, eTriggerPrice, eIsLong);

        emit OrderCreated(msg.sender, token);
    }

    // -------------------------------------------------
    // CANCEL ORDER
    // -------------------------------------------------

    function cancelOrder(uint256 orderId) external {
        (address trader, , euint64 eCollateral, , , ) = orderManager.getOrderMeta(orderId);
        orderManager.cancelOrder(orderId, msg.sender);
        // Refund encrypted collateral — no plaintext amount needed.
        FHE.allow(eCollateral, address(vault));
        vault.refundCollateral(trader, eCollateral);
    }

    // -------------------------------------------------
    // EXECUTE ORDER (KEEPERS) — three-phase
    // -------------------------------------------------

    /**
     * @notice Phase 1 for limit-order execution — submit BOTH the encrypted liquidity check
     *         and the encrypted price check for this order. Keepers decrypt both handles
     *         off-chain, then call executeOrder with the dual proof.
 *
@param orderId Order to be executed.
     * @return hasLiqHandle    Handle for the liquidity-sufficient boolean.
     * @return shouldExecHandle Handle for the price-condition boolean.
     */
    function submitDecryptTaskForOrder(uint256 orderId)
        external
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

        // Compute encrypted size for the liquidity check.
        euint64 eSize = FHE.mul(eCollateral, eLeverage);
        FHE.allow(eSize, address(vault));
        vault.submitReserveLiquidityCheck(trader, eSize);

        // Compute encrypted price check.
        uint256 oraclePrice = _getOraclePrice(token);
        shouldExecHandle = orderManager.submitPriceCheck(orderId, oraclePrice);

        // hasLiqHandle is in the ReserveLiquidityCheckSubmitted event from the vault.
        // Return it from the pending struct for convenience.
        ( , hasLiqHandle) = _getPendingLiqHandle(trader);
    }

    /**
     * @notice Phase 2 for limit-order execution — verify both the liquidity proof and the
     *         price-condition proof, then open the position if both pass.
 *
@param orderId          Order to execute.
     * @param shouldExecPlain  Decrypted price-condition boolean.
     * @param shouldExecSig    Threshold Network signature for shouldExec.
     * @param hasLiqPlain      Decrypted liquidity-sufficient boolean.
     * @param hasLiqSig        Threshold Network signature for hasLiq.
     */
    function executeOrder(
        uint256 orderId,
        bool    shouldExecPlain,
        bytes calldata shouldExecSig,
        bool    hasLiqPlain,
        bytes calldata hasLiqSig
    ) external {
        (
            address trader,
            address token,
            euint64 eCollateral,
            euint64 eLeverage,
            ebool eIsLong
        ) = orderManager.executeOrder(orderId, shouldExecPlain, shouldExecSig);


        // Verify CoFHE liquidity proof for the order's trader.
        vault.storeReserveLiquidityProof(trader, hasLiqPlain, hasLiqSig);

        // Allow positionManager to use the collateral handle.
        FHE.allow(eCollateral, address(positionManager));

        positionManager.openPositionFHE(trader, token, eCollateral, eLeverage, eIsLong);

        emit OrderExecuted(orderId);
    }

    // -------------------------------------------------
    // LIQUIDITY FUNCTIONS
    // -------------------------------------------------

    /**
     * @notice Add liquidity to ShadeSpot vault using FHE token.
     *         The collateral amount is encrypted client-side — never appears in calldata.
     * @dev Caller must have granted this router operator status on the FHE token.
     */
    function addLiquidity(InEuint64 calldata encAmount) external {
        euint64 eAmount = FHE.asEuint64(encAmount);
        FHE.allow(eAmount, address(collateralToken));
        FHE.allow(eAmount, address(vault));
        FHE.allow(eAmount, msg.sender);

        collateralToken.confidentialTransferFrom(msg.sender, address(vault), eAmount);
        // Pass the euint64 handle directly — vault.deposit(address, euint64).
        vault.deposit(msg.sender, eAmount);

        emit AddLiquidity(msg.sender, euint64.unwrap(eAmount));
    }

    /**
     * @notice Phase 1 of remove liquidity: compute the encrypted share-to-token ratio and
     *         submit the FHE checks. Wait for off-chain decrypt (~15–30 s on live networks)
     *         then call removeLiquidity with the proof values.
     * @param shares Standard share amount to redeem.
     */
    function submitWithdrawCheck(uint256 shares) external {
        vault.submitWithdrawCheck(msg.sender, shares);
    }

    /**
     * @notice Phase 2 of remove liquidity: verify decrypt proofs and execute the withdrawal.
     *         Payout is sent as an encrypted euint64 transfer — exact amount never exposed.
     * @param shares     Must match the value passed to submitWithdrawCheck.
     * @param balPlain   Decrypted balance-check boolean.
     * @param balSig     Threshold Network signature for hasBal.
     * @param liqPlain   Decrypted liquidity-check boolean.
     * @param liqSig     Threshold Network signature for hasLiq.
     */
    function removeLiquidity(
        uint256 shares,
        bool    balPlain,
        bytes calldata balSig,
        bool    liqPlain,
        bytes calldata liqSig
    ) external {
        bytes32 amountHandle = vault.withdrawWithProof(
            msg.sender, shares, balPlain, balSig, liqPlain, liqSig
        );
        // Emit the ciphertext handle — authorised party (LP) decrypts client-side.
        emit RemoveLiquidity(msg.sender, amountHandle);
    }

    // -------------------------------------------------
    // INTERNAL HELPERS
    // -------------------------------------------------

    function _getOraclePrice(address token) internal view returns (uint256) {
        return positionManager.oracle().getPrice(token);  // exposed via positionManager
    }

    /**
     * @notice Read the pending liq-check handle from FHEVault for a trader.
     *         Returns (hasLiq ebool, hasLiqHandle bytes32) — used by submitDecryptTaskForOrder
     *         to return the handle to the keeper without an extra event.
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
