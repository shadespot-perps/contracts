// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVault.sol";
import "../oracle/PriceOracle.sol";
import "./FHEFundingRateManager.sol";
import { FHE, euint64, euint128, ebool } from "cofhe-contracts/FHE.sol";

contract PositionManager {
    mapping(bytes32 positionKey => euint128 finalAmountHandle) internal pendingFinalAmount;

    event CloseRequested(
        bytes32 indexed positionKey,
        address indexed trader,
        bytes32 finalAmountHandle,
        bytes32 sizeHandle
    );
    event CloseFinalized(
        bytes32 indexed positionKey,
        address indexed trader,
        bytes32 finalAmountHandle
    );

    mapping(bytes32 positionKey => ebool canLiquidateHandle) internal pendingCanLiquidate;
    event LiquidationRequested(
        bytes32 indexed positionKey,
        address indexed trader,
        bytes32 canLiquidateHandle
    );
    event LiquidationFinalized(
        bytes32 indexed positionKey,
        address indexed trader,
        address indexed liquidator,
        bytes32 collateralHandle,
        bytes32 sizeHandle
    );

    struct Position {
        address owner;
        address indexToken;
        euint128 size;
        euint128 collateral;
        euint128 entryPrice;
        euint128 entryFundingRateBiased;
        euint128 eLeverage;
        ebool isLong;
        bool exists;
        uint256 leverage;
    }

    mapping(bytes32 => Position) private positions;
    mapping(address => uint256) private _positionNonce;
    mapping(address => mapping(address => mapping(bool => bytes32))) private _traderPositionKey;

    IVault public vault;
    PriceOracle public oracle;
    FHEFundingRateManager public fundingManagerFHE;

    address public owner;
    address public router;
    /// @notice FHERouter address authorized to call openPositionFHE.
    address public fheRouter;
    address public liquidationManager;
    /// @notice Trusted account that submits decrypt proofs for finalization.
    address public finalizer;

    uint256 public constant MAX_LEVERAGE = 10;
    uint256 public constant LIQUIDATION_THRESHOLD = 80;
    uint256 public constant FUNDING_PRECISION = 1e12;
    uint256 public constant MIN_COLLATERAL = 1e6;
    /// @notice Funding-rate offset used to avoid signed arithmetic in encrypted storage.
    uint128 public constant FUNDING_RATE_BIAS = 1e20;

    event PositionOpened(
        bytes32 indexed positionKey,
        address indexed trader,
        bytes32 sizeHandle,
        bytes32 collateralHandle,
        bytes32 isLongHandle
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

    /// @notice Sets the encrypted funding rate manager.
    function setFHEFundingManager(address _fheFM) external onlyOwner {
        fundingManagerFHE = FHEFundingRateManager(_fheFM);
    }

    modifier onlyFHERouter() {
        require(msg.sender == fheRouter, "only fheRouter");
        _;
    }

    /// @dev Generates a nonce-based key that omits direction.
    function _mintPositionKey(address trader, address token, bool isLong) internal returns (bytes32) {
        uint256 nonce = _positionNonce[trader]++;
        bytes32 key = keccak256(abi.encode(trader, token, nonce));
        _traderPositionKey[trader][token][isLong] = key;
        return key;
    }

    /// @notice Returns the caller's position key for a token and direction.
    function getMyPositionKey(address token, bool isLong) external view returns (bytes32) {
        return _traderPositionKey[msg.sender][token][isLong];
    }

    /// @notice Returns a trader position key for authorized protocol contracts.
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

    /// @notice Returns the caller's own position.
    function getMyPosition(bytes32 key) external view returns (Position memory) {
        require(positions[key].owner == msg.sender, "not your position");
        return positions[key];
    }

    function _getPosition(bytes32 key) internal view returns (Position storage) {
        return positions[key];
    }

    /// @notice Returns whether a position exists for the provided key.
    function positionExists(bytes32 key) external view returns (bool) {
        return positions[key].exists;
    }

    /**
     * @notice Opens a leveraged position using encrypted collateral.
     * @param trader       Trader address.
     * @param token        Index token.
     * @param eCollateral  Encrypted collateral.
     */
    function openPositionFHE(
        address trader,
        address token,
        euint64 eCollateral,
        euint64 eLeverage,
        ebool   eIsLong
    ) external onlyFHERouter returns (bytes32 positionId) {

        positionId = keccak256(abi.encodePacked(trader, token, _positionNonce[trader]++));

        euint128 eCollateral128 = FHE.asEuint128(eCollateral);
        euint128 eLeverage128   = FHE.asEuint128(eLeverage);
        euint128 eSize          = FHE.mul(eCollateral128, eLeverage128);
        uint256  pricePlain     = oracle.getPrice(token);
        euint128 ePrice         = FHE.asEuint128(pricePlain);

        FHE.allow(eCollateral128, address(this));
        FHE.allow(eSize,          address(this));
        FHE.allow(ePrice,         address(this));
        FHE.allow(eIsLong,        address(this));
        FHE.allow(eLeverage128,   address(this));

        FHE.allow(eSize,          trader);
        FHE.allow(eCollateral128, trader);
        FHE.allow(ePrice,         trader);
        FHE.allow(eLeverage128,   trader);
        FHE.allow(eIsLong,        trader);

        euint128 eFundingRate = fundingManagerFHE.getFundingRateBiased(token);
        FHE.allow(eFundingRate, address(this));
        FHE.allow(eFundingRate, trader);

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
            leverage:               0
        });

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

    function requestClosePosition(
        address trader,
        bytes32 positionId
    ) public onlyFHERouter {
        _requestClosePosition(positionId, trader, positions[positionId].indexToken);
    }

    function _requestClosePosition(bytes32 key, address trader, address token) internal {
    Position storage position = positions[key];
    require(position.exists, "position does not exist");

    FHE.allowTransient(position.size, address(this));
    FHE.allowTransient(position.collateral, address(this));
    FHE.allowTransient(position.entryPrice, address(this));
    FHE.allowTransient(position.isLong, address(this));
    FHE.allowTransient(position.entryFundingRateBiased, address(this));

    uint256 price = oracle.getPrice(token);


    ebool canLiquidateEnc = _checkLiquidatable(position, price);

    pendingCanLiquidate[key] = canLiquidateEnc;
    FHE.allow(canLiquidateEnc, address(this));
    FHE.allow(canLiquidateEnc, liquidationManager);
    euint128 ePnl        = computePnl(position, price);
    euint128 eFundingFee = computeFundingFee(position);

    ebool feeExceedsPnl = FHE.gt(eFundingFee, ePnl);
    euint128 eNetPnl = FHE.select(
        feeExceedsPnl,
        FHE.asEuint128(0),
        FHE.sub(ePnl, eFundingFee)
    );

    euint128 ePrice = FHE.asEuint128(price);

    ebool isProfit = FHE.select(
        position.isLong,
        FHE.gte(ePrice, position.entryPrice),
        FHE.lte(ePrice, position.entryPrice)
    );

    euint128 eFinalAmount = FHE.select(
        isProfit,
        FHE.add(position.collateral, eNetPnl),
        FHE.sub(position.collateral, eNetPnl)
    );

    pendingFinalAmount[key] = eFinalAmount;

    FHE.allow(eFinalAmount, address(this));
    FHE.allow(eFinalAmount, trader);
    FHE.allow(position.size, trader);

    FHE.allow(eFinalAmount,        finalizer);
    FHE.allow(position.size,       finalizer);
    FHE.allow(position.isLong,     finalizer);
    FHE.allow(position.collateral, finalizer);

    emit CloseRequested(
        key,
        trader,
        euint128.unwrap(eFinalAmount),
        euint128.unwrap(position.size)
    );
}


/// @notice Finalizes a close request after decrypt proofs are provided.
/// @param positionKey           Position identifier.
/// @param finalAmount           Decrypted settlement amount in collateral tokens.
/// @param finalAmountSignature  CoFHE proof publishing the finalAmount decrypt.
/// @param sizePlain             Decrypted position size.
/// @param sizeSignature         CoFHE proof publishing the size decrypt.
/// @param collateralPlain       Decrypted original collateral.
/// @param collateralSignature   CoFHE proof for the collateral handle.
/// @param isLongPlain           Deprecated legacy parameter.
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

    FHE.publishDecryptResult(eFinalAmount,      uint128(finalAmount),    finalAmountSignature);
    FHE.publishDecryptResult(position.size,     uint128(sizePlain),      sizeSignature);
    FHE.publishDecryptResult(position.collateral, uint128(collateralPlain), collateralSignature);

    FHE.allowTransient(position.eLeverage, address(this));
    FHE.allowTransient(position.isLong,    address(this));
    fundingManagerFHE.decreaseOpenInterestFHE(token, position.eLeverage, position.isLong);

    vault.releaseLiquidity(sizePlain);
    if (finalAmount >= collateralPlain) {
        uint256 profit = finalAmount - collateralPlain;
        vault.payTrader(trader, profit, collateralPlain);
    } else {
        vault.receiveLoss(collateralPlain - finalAmount);
        vault.payTrader(trader, 0, finalAmount);
    }

    delete positions[key];
    pendingFinalAmount[key]  = euint128.wrap(bytes32(0));
    pendingCanLiquidate[key] = ebool.wrap(bytes32(0));

    emit PositionClosed(key, trader);
    emit CloseFinalized(key, trader, euint128.unwrap(eFinalAmount));
}

    function computePnl(
        Position memory position,
        uint256 price
    ) public returns (euint128) {

        euint128 ePrice = FHE.asEuint128(price);

        euint128 diffLong  = FHE.select(FHE.gt(ePrice, position.entryPrice),
                                        FHE.sub(ePrice, position.entryPrice),
                                        FHE.sub(position.entryPrice, ePrice));

        euint128 diffShort = FHE.select(FHE.gt(position.entryPrice, ePrice),
                                        FHE.sub(position.entryPrice, ePrice),
                                        FHE.sub(ePrice, position.entryPrice));

        euint128 diff = FHE.select(position.isLong, diffLong, diffShort);

        euint128 numerator = FHE.mul(diff, position.size);
        euint128 ePnl      = FHE.div(numerator, position.entryPrice);

        return ePnl;
    }
    function computeFundingFee(
        Position memory position
    ) public returns (euint128) {
        euint128 eCurrentBiased = fundingManagerFHE.getFundingRateBiased(position.indexToken);

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
   function _checkLiquidatable(
    Position storage position,
    uint256 price
) internal returns (ebool) {
    euint128 ePrice = FHE.asEuint128(price);

    euint128 ePnl        = computePnl(position, price);
    euint128 eFundingFee = computeFundingFee(position);
    euint128 eTotalLoss  = FHE.add(ePnl, eFundingFee);

    ebool longLoss  = FHE.lt(ePrice, position.entryPrice);
    ebool shortLoss = FHE.gt(ePrice, position.entryPrice);
    ebool isAtLoss  = FHE.select(position.isLong, longLoss, shortLoss);

    euint128 threshold = FHE.div(
        FHE.mul(position.collateral, FHE.asEuint128(LIQUIDATION_THRESHOLD)),
        FHE.asEuint128(100)
    );

    ebool meetsThreshold = FHE.gte(eTotalLoss, threshold);

    return FHE.and(isAtLoss, meetsThreshold);
}
    /// @notice Requests liquidation eligibility for a position.
    function requestLiquidationCheck(
        bytes32 positionId,
        address liquidator
    ) public onlyLiquidationManager {

    bytes32 key = positionId;
    Position storage position = positions[key];
    address token = position.indexToken;
    address trader = position.owner;
    require(position.exists, "no position");

    FHE.allowTransient(position.size, address(this));
    FHE.allowTransient(position.collateral, address(this));
    FHE.allowTransient(position.entryPrice, address(this));
    FHE.allowTransient(position.isLong, address(this));
    FHE.allowTransient(position.entryFundingRateBiased, address(this));

    uint256 price  = oracle.getPrice(token);
    euint128 ePrice = FHE.asEuint128(price);

    euint128 ePnl        = computePnl(position, price);
    euint128 eFundingFee = computeFundingFee(position);

    euint128 eTotalLoss  = FHE.add(ePnl, eFundingFee);

    ebool longLoss  = FHE.lt(ePrice, position.entryPrice);
    ebool shortLoss = FHE.gt(ePrice, position.entryPrice);
    ebool isAtLoss  = FHE.select(position.isLong, longLoss, shortLoss);

    euint128 threshold = FHE.div(
        FHE.mul(position.collateral, FHE.asEuint128(LIQUIDATION_THRESHOLD)),
        FHE.asEuint128(100)
    );

    ebool meetsThreshold  = FHE.gte(eTotalLoss, threshold);
    ebool canLiquidateEnc = FHE.and(isAtLoss, meetsThreshold);

    pendingCanLiquidate[key] = canLiquidateEnc;
    FHE.allow(canLiquidateEnc, address(this));
    FHE.allow(canLiquidateEnc, liquidationManager);
    FHE.allow(position.collateral, trader);
    FHE.allow(position.size, trader);
    
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

        FHE.allowTransient(position.eLeverage, address(this));
        FHE.allowTransient(position.isLong,    address(this));
        fundingManagerFHE.decreaseOpenInterestFHE(token, position.eLeverage, position.isLong);

        vault.releaseLiquidity(sizePlain);

        uint256 reward = (collateralPlain * 5) / 100;
        vault.receiveLoss(collateralPlain - reward);
        vault.payTrader(liquidator, 0, reward);

        delete positions[key];
        pendingCanLiquidate[key] = ebool.wrap(bytes32(0));

        emit PositionLiquidated(key, trader);
        emit LiquidationFinalized(
            key,
            trader,
            liquidator,
            euint128.unwrap(position.collateral),
            euint128.unwrap(position.size)
        );
    }

    // Backward-compatible aliases for existing integrations.
    function requestClosePositionFHE(
        address trader,
        bytes32 positionId
    ) external {
        requestClosePosition(trader, positionId);
    }

    function calculatePnL(
        Position memory position,
        uint256 price
    ) external returns (euint128) {
        return computePnl(position, price);
    }

    function calculateFundingFee(
        Position memory position
    ) external returns (euint128) {
        return computeFundingFee(position);
    }

    function liquidate(
        bytes32 positionId,
        address liquidator
    ) external {
        requestLiquidationCheck(positionId, liquidator);
    }

}