// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IVault.sol";
import "../oracle/PriceOracle.sol";
import "./FundingRateManager.sol";
import "cofhe-contracts/FHE.sol";

contract PositionManager {
    // When close is requested, we store the computed settlement handle so
    // an off-chain client can decryptForTx and finalize with proof.
    mapping(bytes32 positionKey => euint128 finalAmountHandle) public pendingFinalAmount;
    event CloseRequested(bytes32 indexed positionKey, address indexed trader, address indexed token, bool isLong, bytes32 finalAmountHandle);
    event CloseFinalized(bytes32 indexed positionKey, address indexed trader, address indexed token, bool isLong, uint256 finalAmount, uint256 size);

    // Liquidation is also a request/finalize flow (decrypt-with-proof).
    mapping(bytes32 positionKey => ebool canLiquidateHandle) public pendingCanLiquidate;
    event LiquidationRequested(bytes32 indexed positionKey, address indexed trader, address indexed token, bool isLong, bytes32 canLiquidateHandle);
    event LiquidationFinalized(bytes32 indexed positionKey, address indexed trader, address indexed token, bool isLong, address liquidator, uint256 collateral, uint256 size);

    struct Position {
        address owner;
        address indexToken;
        euint128 size;
        euint128 collateral;
        euint128 entryPrice;
        int256 entryFundingRate;
        ebool isLong;
        bool exists;
    }

    mapping(bytes32 => Position) public positions;

    IVault public vault;
    PriceOracle public oracle;
    FundingRateManager public fundingManager;

    address public owner;
    address public router;
    address public liquidationManager;

    uint256 public constant MAX_LEVERAGE = 10;
    uint256 public constant LIQUIDATION_THRESHOLD = 80;
    uint256 public constant FUNDING_PRECISION = 1e12;
    uint256 public constant MIN_COLLATERAL = 1e6;

    event PositionOpened(address trader, address token, uint256 size, uint256 collateral, bool isLong);
    event PositionClosed(address trader, address token);
    event PositionLiquidated(address trader, address token);

    constructor(address _vault, address _oracle, address _fundingManager) {
        vault = IVault(_vault);
        oracle = PriceOracle(_oracle);
        fundingManager = FundingRateManager(_fundingManager);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyRouter() {
        require(msg.sender == router, "only router");
        _;
    }

    modifier onlyLiquidationManager() {
        require(msg.sender == liquidationManager, "only liquidation manager");
        _;
    }

    function setRouter(address _router) external onlyOwner {
        require(router == address(0), "Already set");
        router = _router;
    }

    function setLiquidationManager(address _liq) external onlyOwner {
        liquidationManager = _liq;
    }

    function getPositionKey(address trader, address token, bool isLong)
        public pure returns (bytes32)
    {
        return keccak256(abi.encode(trader, token, isLong));
    }

    function getPosition(bytes32 key) external view returns (Position memory) {
        return positions[key];
    }

    // =========================================================
    // OPEN POSITION
    // =========================================================

    function openPosition(
        address trader,
        address token,
        uint256 collateral,
        uint256 leverage,
        bool isLong
    ) external onlyRouter {

        require(leverage <= MAX_LEVERAGE, "exceeds max leverage");
        require(collateral >= MIN_COLLATERAL, "collateral below minimum");

        uint256 sizePlain = collateral * leverage;
        uint256 pricePlain = oracle.getPrice(token);

        bytes32 key = getPositionKey(trader, token, isLong);
        require(!positions[key].exists, "position exists");

        // Encrypt all sensitive position fields
        euint128 eCollateral = FHE.asEuint128(collateral);
        euint128 eLeverage   = FHE.asEuint128(leverage);
        euint128 eSize       = FHE.mul(eCollateral, eLeverage);
        euint128 ePrice      = FHE.asEuint128(pricePlain);
        ebool    eIsLong     = FHE.asEbool(isLong);

        // CoFHE ACL: some TaskManager deployments enforce ACL checks on FHE ops.
        // Persistently allow this contract to use these handles across txs.
        FHE.allow(eCollateral, address(this));
        FHE.allow(eLeverage, address(this));
        FHE.allow(eSize, address(this));
        FHE.allow(ePrice, address(this));
        FHE.allow(eIsLong, address(this));

        int256 fundingRate = fundingManager.getFundingRate(token);

        vault.reserveLiquidity(sizePlain, trader);

        positions[key] = Position({
            owner: trader,
            indexToken: token,
            size: eSize,
            collateral: eCollateral,
            entryPrice: ePrice,
            entryFundingRate: fundingRate,
            isLong: eIsLong,
            exists: true
        });

        fundingManager.increaseOpenInterest(token, sizePlain, isLong);

        emit PositionOpened(trader, token, sizePlain, collateral, isLong);
    }

    // =========================================================
    // CLOSE POSITION (request + finalize)
    // =========================================================

    function requestClosePosition(
        address trader,
        address token,
        bool isLong
    ) external onlyRouter {

    bytes32 key = getPositionKey(trader, token, isLong);
    Position storage position = positions[key];
    require(position.exists, "position does not exist");

    // CoFHE ACL: allow this contract to operate on stored ciphertext handles in this tx.
    FHE.allowTransient(position.size, address(this));
    FHE.allowTransient(position.collateral, address(this));
    FHE.allowTransient(position.entryPrice, address(this));
    FHE.allowTransient(position.isLong, address(this));

    uint256 price = oracle.getPrice(token);


    ebool canLiquidateEnc = _checkLiquidatable(position, price);

    // store for finalize step
    pendingCanLiquidate[key] = canLiquidateEnc;
    FHE.allowPublic(canLiquidateEnc);
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

    // Allow public decryption (docs pattern).
    FHE.allowPublic(eFinalAmount);
    FHE.allowPublic(position.size);

    emit CloseRequested(key, trader, token, isLong, euint128.unwrap(eFinalAmount));
}


function finalizeClosePosition(
    address trader,
    address token,
    bool isLong,
    uint256 finalAmount,
    bytes calldata finalAmountSignature,
    uint256 sizePlain,
    bytes calldata sizeSignature,
    bool canLiquidatePlain,
    bytes calldata canLiquidateSignature
) external {

    bytes32 key = getPositionKey(trader, token, isLong);
    Position storage position = positions[key];
    require(position.exists, "position does not exist");

    euint128 eFinalAmount = pendingFinalAmount[key];
    require(euint128.unwrap(eFinalAmount) != bytes32(0), "close not requested");

    ebool canLiquidateEnc = pendingCanLiquidate[key];
    require(ebool.unwrap(canLiquidateEnc) != bytes32(0), "liquidation check missing");

    // verify decryptions
    FHE.publishDecryptResult(
        canLiquidateEnc,
        canLiquidatePlain,
        canLiquidateSignature
    );

    // block close if liquidatable
    require(!canLiquidatePlain, "position liquidatable");

    FHE.publishDecryptResult(
        eFinalAmount,
        uint128(finalAmount),
        finalAmountSignature
    );

    FHE.publishDecryptResult(
        position.size,
        uint128(sizePlain),
        sizeSignature
    );

    // finalize
    vault.releaseLiquidity(sizePlain);
    vault.payTrader(trader, 0, finalAmount);
    fundingManager.decreaseOpenInterest(token, sizePlain, isLong);

    delete positions[key];
    pendingFinalAmount[key] = euint128.wrap(bytes32(0));
    pendingCanLiquidate[key] = ebool.wrap(bytes32(0));

    emit PositionClosed(trader, token);
    emit CloseFinalized(key, trader, token, isLong, finalAmount, sizePlain);
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

        int256 currentFunding = fundingManager.getFundingRate(position.indexToken);
        int256 fundingDiff    = currentFunding - position.entryFundingRate;

        // Both the current rate and entry rate are public scalars, so the diff
        // magnitude is known without touching the encrypted size. We multiply the
        // encrypted size by this plaintext scalar entirely inside FHE — no decrypt.
        uint256 diffMagnitude = fundingDiff >= 0
            ? uint256(fundingDiff)
            : uint256(-fundingDiff);

        return FHE.div(
            FHE.mul(position.size, FHE.asEuint128(diffMagnitude)),
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
        address trader,
        address token,
        bool isLong,
        address /* liquidator */
    ) external onlyLiquidationManager {

    // ─────────────────────────────────────────────
    // 1. BASIC CHECKS (plaintext only)
    // ─────────────────────────────────────────────
    bytes32 key = getPositionKey(trader, token, isLong);
    Position storage position = positions[key];
    require(position.exists, "no position");

    // CoFHE ACL: allow this contract to operate on stored ciphertext handles in this tx.
    FHE.allowTransient(position.size, address(this));
    FHE.allowTransient(position.collateral, address(this));
    FHE.allowTransient(position.entryPrice, address(this));
    FHE.allowTransient(position.isLong, address(this));

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
    FHE.allowPublic(canLiquidateEnc);
    FHE.allowPublic(position.collateral);
    FHE.allowPublic(position.size);
    emit LiquidationRequested(key, trader, token, isLong, ebool.unwrap(canLiquidateEnc));
}

    function finalizeLiquidation(
        address trader,
        address token,
        bool isLong,
        address liquidator,
        bool canLiquidatePlain,
        bytes calldata canLiquidateSignature,
        uint256 collateralPlain,
        bytes calldata collateralSignature,
        uint256 sizePlain,
        bytes calldata sizeSignature
    ) external onlyLiquidationManager {
        bytes32 key = getPositionKey(trader, token, isLong);
        Position storage position = positions[key];
        require(position.exists, "no position");

        ebool canLiquidateEnc = pendingCanLiquidate[key];
        require(ebool.unwrap(canLiquidateEnc) != bytes32(0), "liquidation not requested");

        FHE.publishDecryptResult(canLiquidateEnc, canLiquidatePlain, canLiquidateSignature);
        FHE.publishDecryptResult(position.collateral, uint128(collateralPlain), collateralSignature);
        FHE.publishDecryptResult(position.size, uint128(sizePlain), sizeSignature);

        require(canLiquidatePlain, "not liquidatable");

        vault.releaseLiquidity(sizePlain);

        uint256 reward = (collateralPlain * 5) / 100;
        vault.receiveLoss(collateralPlain - reward);
        vault.payTrader(liquidator, 0, reward);

        fundingManager.decreaseOpenInterest(token, sizePlain, isLong);

        delete positions[key];
        pendingCanLiquidate[key] = ebool.wrap(bytes32(0));

        emit PositionLiquidated(trader, token);
        emit LiquidationFinalized(key, trader, token, isLong, liquidator, collateralPlain, sizePlain);
    }

}