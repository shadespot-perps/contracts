// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVault.sol";
import "../oracle/PriceOracle.sol";
import "./FHEFundingRateManager.sol";
import { FHE, euint64, euint128, ebool } from "cofhe-contracts/FHE.sol";

contract PositionManager {
    // When close is requested, we store the computed settlement handle so
    // an off-chain client can decryptForTx and finalize with proof.
    mapping(bytes32 positionKey => euint128 finalAmountHandle) internal pendingFinalAmount;

    // Emits encrypted handles only — observers see opaque bytes32.
    // Trader decrypts client-side via CoFHE SDK (FHE.allow grants access).
    event CloseRequested(
        bytes32 indexed positionKey,
        address indexed trader,
        bytes32 finalAmountHandle, // euint128 — trader-decryptable
        bytes32 sizeHandle         // euint128 — trader-decryptable
    );
    event CloseFinalized(
        bytes32 indexed positionKey,
        address indexed trader,
        bytes32 finalAmountHandle  // euint128 — trader-decryptable payout
    );

    // Liquidation is also a request/finalize flow (decrypt-with-proof).
    mapping(bytes32 positionKey => ebool canLiquidateHandle) internal pendingCanLiquidate;
    event LiquidationRequested(
        bytes32 indexed positionKey,
        address indexed trader,
        bytes32 canLiquidateHandle // ebool — liquidationManager-decryptable
    );
    event LiquidationFinalized(
        bytes32 indexed positionKey,
        address indexed trader,
        address indexed liquidator,
        bytes32 collateralHandle,  // euint128 — trader-decryptable
        bytes32 sizeHandle         // euint128 — trader-decryptable
    );

    struct Position {
        address owner;
        address indexToken;
        euint128 size;
        euint128 collateral;
        euint128 entryPrice;
        euint128 entryFundingRateBiased; // stored as (rate + FUNDING_RATE_BIAS) — always positive
        euint128 eLeverage;              // encrypted leverage — needed for OI decrease on close/liquidation
        ebool isLong;
        bool exists;
        uint256 leverage;
    }

    mapping(bytes32 => Position) private positions;
    // Per-trader nonce so position keys don't encode direction (isLong).
    // Key = keccak256(trader, token, nonce) — direction is fully private.
    mapping(address => uint256) private _positionNonce;
    // Reverse mapping: lets the trader look up their own key given token + isLong.
    mapping(address => mapping(address => mapping(bool => bytes32))) private _traderPositionKey;

    IVault public vault;
    PriceOracle public oracle;
    FHEFundingRateManager public fundingManagerFHE;

    address public owner;
    address public router;
    /// @notice FHERouter address — authorized to call openPositionFHE for ShadeSpot.
    address public fheRouter;
    address public liquidationManager;
    // Trusted CoFHE dispatcher that submits decrypt proofs to finalize positions.
    address public finalizer;

    uint256 public constant MAX_LEVERAGE = 10;
    uint256 public constant LIQUIDATION_THRESHOLD = 80;
    uint256 public constant FUNDING_PRECISION = 1e12;
    uint256 public constant MIN_COLLATERAL = 1e6;
    // Bias applied before storing entryFundingRate as euint128.
    // Covers ±1e20, safe for >11,000 years at max 1e12/hour accumulation.
    uint128 public constant FUNDING_RATE_BIAS = 1e20;

    // Encrypted handles emitted — only trader can decrypt via CoFHE SDK.
    // Observers see opaque bytes32 ciphertexts with no plaintext leakage.
    event PositionOpened(
        bytes32 indexed positionKey,
        address indexed trader,
        bytes32 sizeHandle,        // euint128 — trader-decryptable
        bytes32 collateralHandle,  // euint128 — trader-decryptable
        bytes32 isLongHandle       // ebool    — trader-decryptable
    );
    event PositionClosed(bytes32 indexed positionKey, address indexed trader);
    event PositionLiquidated(bytes32 indexed positionKey, address indexed trader);

    constructor(address _vault, address _oracle) {
        vault = IVault(_vault);
        oracle = PriceOracle(_oracle);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyLiquidationManager() {
        require(msg.sender == liquidationManager, "only liquidation manager");
        _;
    }

    modifier onlyFinalizer() {
        require(msg.sender == finalizer, "only finalizer");
        _;
    }

    function setRouter(address _router) external onlyOwner {
        require(router == address(0), "Already set");
        router = _router;
    }

    function setFheRouter(address _fheRouter) external onlyOwner {
        require(fheRouter == address(0), "Already set");
        fheRouter = _fheRouter;
    }

    function setLiquidationManager(address _liq) external onlyOwner {
        liquidationManager = _liq;
    }

    function setFinalizer(address _finalizer) external onlyOwner {
        finalizer = _finalizer;
    }

    /// @notice Set a new FundingRateManager (idempotent — can be updated by owner).

    /// @notice Wire up the encrypted FHE Funding Rate Manager.
    function setFHEFundingManager(address _fheFM) external onlyOwner {
        fundingManagerFHE = FHEFundingRateManager(_fheFM);
    }

    modifier onlyFHERouter() {
        require(msg.sender == fheRouter, "only fheRouter");
        _;
    }

    /// @dev Generates a nonce-based key — direction is NOT encoded, preventing brute-force.
    function _mintPositionKey(address trader, address token, bool isLong) internal returns (bytes32) {
        uint256 nonce = _positionNonce[trader]++;
        bytes32 key = keccak256(abi.encode(trader, token, nonce));
        _traderPositionKey[trader][token][isLong] = key;
        return key;
    }

    /// @notice Returns the caller's own position key for a given token + direction.
    ///         Only the trader can retrieve their own key — no public enumeration.
    function getMyPositionKey(address token, bool isLong) external view returns (bytes32) {
        return _traderPositionKey[msg.sender][token][isLong];
    }

    /// @notice Router/LiquidationManager use this to look up a trader's key by address.
    ///         Restricted to authorized protocol contracts only.
    function getTraderPositionKey(address trader, address token, bool isLong)
        external view returns (bytes32)
    {
        require(
            msg.sender == router || msg.sender == liquidationManager ||
            msg.sender == finalizer || msg.sender == owner,
            "unauthorized"
        );
        return _traderPositionKey[trader][token][isLong];
    }

    /// @notice Returns the caller's own position. Reverts for any other address.
    function getMyPosition(bytes32 key) external view returns (Position memory) {
        require(positions[key].owner == msg.sender, "not your position");
        return positions[key];
    }

    /// @notice Internal read used by router and liquidationManager — not callable externally.
    function _getPosition(bytes32 key) internal view returns (Position storage) {
        return positions[key];
    }

    /// @notice Check existence only — safe to expose since key is already known to caller.
    function positionExists(bytes32 key) external view returns (bool) {
        return positions[key].exists;
    }

    // =========================================================
    // OPEN POSITION
    // =========================================================

    // =========================================================
    // OPEN POSITION — FHE PATH (FHERouter)
    // =========================================================

    /**
     * @notice Open a leveraged position using an already-encrypted euint64 collateral.
     *         Called exclusively by FHERouter (ShadeSpot). FHEVault.reserveLiquidity(trader)
     *         reads the pre-approved encrypted size left by storeReserveLiquidityProof —
     *         no unencrypted amount crosses the PositionManager ↔ Vault boundary.
 *
@param trader       Trader address.
     * @param token        Index token.
     * @param eCollateral  Encrypted collateral (euint64). Router must allow this contract
     *                     to use the handle before calling.
     *                     collateral*leverage stays encrypted inside the vault).
 *
NOTE on OI tracking: funding rate open-interest is incremented by `leverage` as a
     * proxy unit because collateral remains strictly encrypted in the FHE path. This is an
     * accepted privacy tradeoff — the long/short skew direction is still correct, and a
     * fully encrypted OI tracker is planned as a future upgrade.
     */
    function openPositionFHE(
        address trader,
        address token,
        euint64 eCollateral,
        euint64 eLeverage,
        ebool   eIsLong
    ) external onlyFHERouter returns (bytes32 positionId) {

        positionId = keccak256(abi.encodePacked(trader, token, _positionNonce[trader]++));

        // Upcast euint64 → euint128 for the position struct.
        // The encrypted value is preserved — no decryption occurs.
        euint128 eCollateral128 = FHE.asEuint128(eCollateral);
        euint128 eLeverage128   = FHE.asEuint128(eLeverage);
        euint128 eSize          = FHE.mul(eCollateral128, eLeverage128);
        uint256  pricePlain     = oracle.getPrice(token);
        euint128 ePrice         = FHE.asEuint128(pricePlain);

        // CoFHE ACL: allow this contract to use handles across txs.
        FHE.allow(eCollateral128, address(this));
        FHE.allow(eSize,          address(this));
        FHE.allow(ePrice,         address(this));
        FHE.allow(eIsLong,        address(this));
        FHE.allow(eLeverage128,   address(this));

        // Ensure FHE limit orders can safely pass their handles without double-allowing
        // We do not re-allow if they already have access from OrderManager
        FHE.allow(eSize,          trader);
        FHE.allow(eCollateral128, trader);
        FHE.allow(ePrice,         trader);
        FHE.allow(eLeverage128,   trader);
        FHE.allow(eIsLong,        trader);

        // Get encrypted funding rate directly
        euint128 eFundingRate = fundingManagerFHE.getFundingRateBiased(token);
        FHE.allow(eFundingRate, address(this));
        FHE.allow(eFundingRate, trader);

        // FHEVault reads its internally stored _liqApprovedSize[trader] — no amount arg.
        vault.reserveLiquidity(trader);

        positions[positionId] = Position({
            owner:                  trader,
            indexToken:             token,
            size:                   eSize,
            collateral:             eCollateral128,
            entryPrice:             ePrice,
            entryFundingRateBiased: eFundingRate,
            eLeverage:              eLeverage128,
            isLong:                 eIsLong,
            exists:                 true,
            leverage:               0 // Plaintext leverage unavailable in fully encrypted FHE mode
        });

        // OI tracking is offloaded to the new encrypted FHEFundingRateManager 
        fundingManagerFHE.increaseOpenInterestFHE(token, eLeverage128, eIsLong);

        emit PositionOpened(
            positionId,
            trader,
            euint128.unwrap(eSize),
            euint128.unwrap(eCollateral128),
            ebool.unwrap(eIsLong)
        );
        return positionId;
    }

    // =========================================================
    // CLOSE POSITION (request + finalize)
    // =========================================================

    function requestClosePositionFHE(
        address trader,
        bytes32 positionId
    ) external onlyFHERouter {
        _requestClosePosition(positionId, trader, positions[positionId].indexToken);
    }

    function _requestClosePosition(bytes32 key, address trader, address token) internal {
    Position storage position = positions[key];
    require(position.exists, "position does not exist");

    // CoFHE ACL: allow this contract to operate on stored ciphertext handles in this tx.
    FHE.allowTransient(position.size, address(this));
    FHE.allowTransient(position.collateral, address(this));
    FHE.allowTransient(position.entryPrice, address(this));
    FHE.allowTransient(position.isLong, address(this));
    FHE.allowTransient(position.entryFundingRateBiased, address(this));

    uint256 price = oracle.getPrice(token);


    ebool canLiquidateEnc = _checkLiquidatable(position, price);

    // store for finalize step; only this contract and liquidationManager need decrypt access
    pendingCanLiquidate[key] = canLiquidateEnc;
    FHE.allow(canLiquidateEnc, address(this));
    FHE.allow(canLiquidateEnc, liquidationManager);
    // ================================
    // 1. FULLY ENCRYPTED COMPUTATION
    // ================================

    euint128 ePnl        = calculatePnL(position, price);
    euint128 eFundingFee = calculateFundingFee(position);

    // net pnl (clamped to >= 0)
    ebool feeExceedsPnl = FHE.gt(eFundingFee, ePnl);
    euint128 eNetPnl = FHE.select(
        feeExceedsPnl,
        FHE.asEuint128(0),
        FHE.sub(ePnl, eFundingFee)
    );

    // ================================
    // 2. DETERMINE PROFIT/LOSS (ENCRYPTED)
    // ================================

    // price comparison in encrypted domain
    euint128 ePrice = FHE.asEuint128(price);

    ebool isProfit = FHE.select(
        position.isLong,
        FHE.gte(ePrice, position.entryPrice),  // long profit
        FHE.lte(ePrice, position.entryPrice)   // short profit
    );

    // ================================
    // 3. FINAL SETTLEMENT (ENCRYPTED)
    // ================================

    euint128 eFinalAmount = FHE.select(
        isProfit,
        FHE.add(position.collateral, eNetPnl),   // profit
        FHE.sub(position.collateral, eNetPnl)    // loss
    );

    // Persist computed handle for later finalize.
    pendingFinalAmount[key] = eFinalAmount;

    // Allow trader (and this contract for finalize) to decrypt — no public access.
    FHE.allow(eFinalAmount, address(this));
    FHE.allow(eFinalAmount, trader);
    FHE.allow(position.size, trader);

    // Allow the finalizer (off-chain Keeper Node.js) to decrypt for settlement
    FHE.allow(eFinalAmount,        finalizer);
    FHE.allow(position.size,       finalizer);
    FHE.allow(position.isLong,     finalizer);
    FHE.allow(position.collateral, finalizer); // needed for profit/loss split in finalizeClosePosition

    emit CloseRequested(
        key,
        trader,
        euint128.unwrap(eFinalAmount),
        euint128.unwrap(position.size)
    );
}


/// @notice Finalizes a previously requested close after the CoFHE Threshold Network decrypts the handles.
/// @param positionKey           The position identifier (keccak256 nonce key or legacy isLong key).
/// @param finalAmount           Decrypted settlement amount in collateral tokens.
/// @param finalAmountSignature  CoFHE proof publishing the finalAmount decrypt.
/// @param sizePlain             Decrypted position size.
/// @param sizeSignature         CoFHE proof publishing the size decrypt.
/// @param collateralPlain       Decrypted original collateral — used to split profit vs. returned collateral.
/// @param collateralSignature   CoFHE proof for the collateral handle.
/// @param isLongPlain           Decrypted direction (legacy param, deprecated).
function finalizeClosePosition(
    bytes32 positionKey,
    uint256 finalAmount,
    bytes calldata finalAmountSignature,
    uint256 sizePlain,
    bytes calldata sizeSignature,
    uint256 collateralPlain,
    bytes calldata collateralSignature,
    bool isLongPlain
) external onlyFinalizer {
    bytes32 key = positionKey;
    Position storage position = positions[key];
    address trader = position.owner;
    address token  = position.indexToken;
    require(position.exists, "position does not exist");

    euint128 eFinalAmount = pendingFinalAmount[key];
    require(euint128.unwrap(eFinalAmount) != bytes32(0), "close not requested");

    // Verify all three Threshold Network proofs — reverts if any signature is invalid.
    FHE.publishDecryptResult(eFinalAmount,      uint128(finalAmount),    finalAmountSignature);
    FHE.publishDecryptResult(position.size,     uint128(sizePlain),      sizeSignature);
    FHE.publishDecryptResult(position.collateral, uint128(collateralPlain), collateralSignature);

    // Decrease open interest now that the position is closed (encrypted — no direction leak).
    FHE.allowTransient(position.eLeverage, address(this));
    FHE.allowTransient(position.isLong,    address(this));
    fundingManagerFHE.decreaseOpenInterestFHE(token, position.eLeverage, position.isLong);

    // Settle with vault — correctly split profit from returned collateral.
    vault.releaseLiquidity(sizePlain);
    if (finalAmount >= collateralPlain) {
        // Position is profitable: return collateral + pay profit from pool.
        uint256 profit = finalAmount - collateralPlain;
        vault.payTrader(trader, profit, collateralPlain);
    } else {
        // Position is a loss: return whatever remains; pool keeps the difference.
        vault.receiveLoss(collateralPlain - finalAmount);
        vault.payTrader(trader, 0, finalAmount);
    }

    delete positions[key];
    pendingFinalAmount[key]  = euint128.wrap(bytes32(0));
    pendingCanLiquidate[key] = ebool.wrap(bytes32(0));

    emit PositionClosed(key, trader);
    emit CloseFinalized(key, trader, euint128.unwrap(eFinalAmount));
}


    // =========================================================
    // PNL  — returns encrypted magnitude (always >= 0)
    // Direction is inferred externally by comparing current vs entry price
    // =========================================================

    function calculatePnL(
        Position memory position,
        uint256 price
    ) public returns (euint128) {

        euint128 ePrice = FHE.asEuint128(price);

        // Compute both branches; select via encrypted isLong — no plaintext branch leak
        euint128 diffLong  = FHE.select(FHE.gt(ePrice, position.entryPrice),
                                        FHE.sub(ePrice, position.entryPrice),
                                        FHE.sub(position.entryPrice, ePrice));

        euint128 diffShort = FHE.select(FHE.gt(position.entryPrice, ePrice),
                                        FHE.sub(position.entryPrice, ePrice),
                                        FHE.sub(ePrice, position.entryPrice));

        // Pick the correct diff based on encrypted direction
        euint128 diff = FHE.select(position.isLong, diffLong, diffShort);

        euint128 numerator = FHE.mul(diff, position.size);
        euint128 ePnl      = FHE.div(numerator, position.entryPrice);

        return ePnl;
    }

    // =========================================================
    // FUNDING FEE — returns encrypted magnitude (always >= 0)
    // =========================================================

    function calculateFundingFee(
        Position memory position
    ) public returns (euint128) {
        euint128 eCurrentBiased = fundingManagerFHE.getFundingRateBiased(position.indexToken);

        // |currentBiased - entryBiased| entirely in FHE — no plaintext diff leaked.
        FHE.allowTransient(position.entryFundingRateBiased, address(this));
        ebool currentGteEntry = FHE.gte(eCurrentBiased, position.entryFundingRateBiased);
        euint128 diffMagnitude = FHE.select(
            currentGteEntry,
            FHE.sub(eCurrentBiased, position.entryFundingRateBiased),
            FHE.sub(position.entryFundingRateBiased, eCurrentBiased)
        );

        return FHE.div(
            FHE.mul(position.size, diffMagnitude),
            FHE.asEuint128(FUNDING_PRECISION)
        );
    }

    // =========================================================
    // LIQUIDATION
    // =========================================================


   function _checkLiquidatable(
    Position storage position,
    uint256 price
) internal returns (ebool) {
    euint128 ePrice = FHE.asEuint128(price);

    // PnL + funding
    euint128 ePnl        = calculatePnL(position, price);
    euint128 eFundingFee = calculateFundingFee(position);
    euint128 eTotalLoss  = FHE.add(ePnl, eFundingFee);

    // Directional loss
    ebool longLoss  = FHE.lt(ePrice, position.entryPrice);
    ebool shortLoss = FHE.gt(ePrice, position.entryPrice);
    ebool isAtLoss  = FHE.select(position.isLong, longLoss, shortLoss);

    // Threshold = 80% collateral
    euint128 threshold = FHE.div(
        FHE.mul(position.collateral, FHE.asEuint128(LIQUIDATION_THRESHOLD)),
        FHE.asEuint128(100)
    );

    ebool meetsThreshold = FHE.gte(eTotalLoss, threshold);

    return FHE.and(isAtLoss, meetsThreshold);
}
    // Backwards-compatible entrypoint used by `LiquidationManager`.
    // It now only requests decryption eligibility; settlement is done in `finalizeLiquidation`.
    function liquidate(
        bytes32 positionId,
        address liquidator
    ) external onlyLiquidationManager {

    // ─────────────────────────────────────────────
    // 1. BASIC CHECKS (plaintext only)
    // ─────────────────────────────────────────────
    bytes32 key = positionId;
    Position storage position = positions[key];
    address token = position.indexToken;
    address trader = position.owner;
    require(position.exists, "no position");

    // CoFHE ACL: allow this contract to operate on stored ciphertext handles in this tx.
    FHE.allowTransient(position.size, address(this));
    FHE.allowTransient(position.collateral, address(this));
    FHE.allowTransient(position.entryPrice, address(this));
    FHE.allowTransient(position.isLong, address(this));
    FHE.allowTransient(position.entryFundingRateBiased, address(this));

    uint256 price  = oracle.getPrice(token);
    euint128 ePrice = FHE.asEuint128(price);

    // ─────────────────────────────────────────────
    // 2. FULLY ENCRYPTED PnL + FUNDING FEE
    //    (best of liquidate_have — kept in FHE domain)
    // ─────────────────────────────────────────────
    euint128 ePnl        = calculatePnL(position, price);
    euint128 eFundingFee = calculateFundingFee(position);

    // Total effective loss includes funding fees
    euint128 eTotalLoss  = FHE.add(ePnl, eFundingFee);

    // ─────────────────────────────────────────────
    // 3. ENCRYPTED DIRECTIONAL LOSS CHECK
    //    (best of liquidate — stays encrypted)
    // ─────────────────────────────────────────────

    // Is price moving against the position?
    ebool longLoss  = FHE.lt(ePrice, position.entryPrice);  // long:  price fell
    ebool shortLoss = FHE.gt(ePrice, position.entryPrice);  // short: price rose
    ebool isAtLoss  = FHE.select(position.isLong, longLoss, shortLoss);

    // threshold = collateral * LIQUIDATION_THRESHOLD / 100  (all encrypted)
    euint128 threshold = FHE.div(
        FHE.mul(position.collateral, FHE.asEuint128(LIQUIDATION_THRESHOLD)),
        FHE.asEuint128(100)
    );

    // Loss must exceed threshold AND position must be at a loss
    ebool meetsThreshold  = FHE.gte(eTotalLoss, threshold);
    ebool canLiquidateEnc = FHE.and(isAtLoss, meetsThreshold);

    pendingCanLiquidate[key] = canLiquidateEnc;
    // Allow liquidationManager to decrypt the eligibility flag; trader can decrypt their own handles.
    FHE.allow(canLiquidateEnc, address(this));
    FHE.allow(canLiquidateEnc, liquidationManager);
    FHE.allow(position.collateral, trader);
    FHE.allow(position.size, trader);
    
    // Allow the specific liquidator (Keeper running the bot) to decrypt handles for finalizeLiquidation
    FHE.allow(canLiquidateEnc, liquidator);
    FHE.allow(position.collateral, liquidator);
    FHE.allow(position.size, liquidator);
    FHE.allow(position.isLong, liquidator);

    emit LiquidationRequested(key, trader, ebool.unwrap(canLiquidateEnc));
}

    function finalizeLiquidation(
        bytes32 positionKey,
        address liquidator,
        bool canLiquidatePlain,
        bytes calldata canLiquidateSignature,
        uint256 collateralPlain,
        bytes calldata collateralSignature,
        uint256 sizePlain,
        bytes calldata sizeSignature,
        bool isLongPlain
    ) external onlyLiquidationManager {
        bytes32 key = positionKey;
        Position storage position = positions[key];
        address trader = position.owner;
        address token = position.indexToken;
        require(position.exists, "no position");

        ebool canLiquidateEnc = pendingCanLiquidate[key];
        require(ebool.unwrap(canLiquidateEnc) != bytes32(0), "liquidation not requested");

        FHE.publishDecryptResult(canLiquidateEnc, canLiquidatePlain, canLiquidateSignature);
        FHE.publishDecryptResult(position.collateral, uint128(collateralPlain), collateralSignature);
        FHE.publishDecryptResult(position.size, uint128(sizePlain), sizeSignature);

        require(canLiquidatePlain, "not liquidatable");

        // Decrease open interest (encrypted — does not leak direction).
        FHE.allowTransient(position.eLeverage, address(this));
        FHE.allowTransient(position.isLong,    address(this));
        fundingManagerFHE.decreaseOpenInterestFHE(token, position.eLeverage, position.isLong);

        vault.releaseLiquidity(sizePlain);

        uint256 reward = (collateralPlain * 5) / 100;
        vault.receiveLoss(collateralPlain - reward);
        vault.payTrader(liquidator, 0, reward);

        delete positions[key];
        pendingCanLiquidate[key] = ebool.wrap(bytes32(0));

        // Handles still valid post-publishDecryptResult; trader can decrypt via SDK.
        emit PositionLiquidated(key, trader);
        emit LiquidationFinalized(
            key,
            trader,
            liquidator,
            euint128.unwrap(position.collateral),
            euint128.unwrap(position.size)
        );
    }

}