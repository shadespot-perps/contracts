// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Vault.sol";
import "../oracle/PriceOracle.sol";
import "./FundingRateManager.sol";
import "cofhe-contracts/FHE.sol";

contract PositionManager {

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

    Vault public vault;
    PriceOracle public oracle;
    FundingRateManager public fundingManager;

    address public owner;
    address public router;
    address public liquidationManager;

    uint256 public constant MAX_LEVERAGE = 10;
    uint256 public constant LIQUIDATION_THRESHOLD = 80;
    uint256 public constant FUNDING_PRECISION = 1e12;

    event PositionOpened(address trader, address token, uint256 size, uint256 collateral, bool isLong);
    event PositionClosed(address trader, address token);
    event PositionLiquidated(address trader, address token);

    constructor(address _vault, address _oracle, address _fundingManager) {
        vault = Vault(_vault);
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
        require(collateral > 0, "invalid collateral");

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

        int256 fundingRate = fundingManager.getFundingRate(token);

        vault.reserveLiquidity(sizePlain);

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
    // CLOSE POSITION
    // =========================================================

    function closePosition(
    address trader,
    address token,
    bool isLong
) external onlyRouter {

    bytes32 key = getPositionKey(trader, token, isLong);
    Position storage position = positions[key];
    require(position.exists, "position does not exist");

    uint256 price = oracle.getPrice(token);

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

    // ================================
    // 4. MINIMAL DECRYPTION (ONLY FINAL)
    // ================================

    (uint256 finalAmount, bool ok) = FHE.getDecryptResultSafe(eFinalAmount);
    require(ok, "decrypt not ready");

    // ================================
    // 5. VAULT INTERACTION
    // ================================

    (uint256 sizePlain, bool ok2) = FHE.getDecryptResultSafe(position.size);
    require(ok2, "decrypt not ready");

    vault.releaseLiquidity(sizePlain);

    vault.payTrader(trader, 0, finalAmount);

    fundingManager.decreaseOpenInterest(token, sizePlain, isLong);

    delete positions[key];

    emit PositionClosed(trader, token);
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

    function liquidate(
    address trader,
    address token,
    bool isLong,
    address liquidator
) external onlyLiquidationManager {

    // ─────────────────────────────────────────────
    // 1. BASIC CHECKS (plaintext only)
    // ─────────────────────────────────────────────
    bytes32 key = getPositionKey(trader, token, isLong);
    Position storage position = positions[key];
    require(position.exists, "no position");

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

    // ─────────────────────────────────────────────
    // 4. DECRYPT ONLY ONE BIT
    //    Minimum information leaked — just the bool
    // ─────────────────────────────────────────────
    (bool canLiquidate, bool okBool) = FHE.getDecryptResultSafe(canLiquidateEnc);
    require(okBool,       "decrypt not ready");
    require(canLiquidate, "not liquidatable");   // hard revert — no silent pass

    // ─────────────────────────────────────────────
    // 5. DECRYPT SETTLEMENT VALUES (only after check passes)
    //    Decrypt the minimum needed for on-chain settlement
    // ─────────────────────────────────────────────
    (uint256 collateralPlain, bool ok1) = FHE.getDecryptResultSafe(position.collateral);
    (uint256 sizePlain,       bool ok2) = FHE.getDecryptResultSafe(position.size);
    require(ok1 && ok2, "decrypt fail");

    // ─────────────────────────────────────────────
    // 6. SETTLEMENT + CLEANUP
    // ─────────────────────────────────────────────
    vault.releaseLiquidity(sizePlain);

    uint256 reward = (collateralPlain * 5) / 100;           // 5% liquidator reward
    vault.receiveLoss(collateralPlain - reward);
    vault.payTrader(liquidator, 0, reward);

    fundingManager.decreaseOpenInterest(token, sizePlain, isLong);

    delete positions[key];

    emit PositionLiquidated(trader, token);
}

}