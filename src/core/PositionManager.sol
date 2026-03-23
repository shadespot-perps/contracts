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

        // PnL and funding fee remain encrypted until final settlement boundary
        euint128 ePnl         = calculatePnL(position, price);
        euint128 eFundingFee  = calculateFundingFee(position);

        // Subtract funding fee from gross PnL (both are non-negative magnitudes;
        // eFundingFee is always <= ePnl in normal operation, but clamp to zero)
        ebool    feeExceedsPnl = FHE.gt(eFundingFee, ePnl);
        euint128 eNetPnl       = FHE.select(feeExceedsPnl, FHE.asEuint128(0), FHE.sub(ePnl, eFundingFee));

        // Decrypt only at the settlement boundary — the single authorised output point
        uint128 netPnlPlain      = FHE.decrypt(eNetPnl);
        uint128 collateralPlain  = FHE.decrypt(position.collateral);
        uint128 sizePlain        = FHE.decrypt(position.size);
        bool    isLongPlain      = FHE.decrypt(position.isLong);

        vault.releaseLiquidity(uint256(sizePlain));

        // Determine signed PnL: positive for longs when price rose, shorts when fell
        int256 signedPnl;
        {
            uint256 currentPrice = oracle.getPrice(token);
            uint128 entryPricePlain = FHE.decrypt(position.entryPrice);
            if (isLongPlain) {
                signedPnl = currentPrice >= entryPricePlain
                    ? int256(uint256(netPnlPlain))
                    : -int256(uint256(netPnlPlain));
            } else {
                signedPnl = currentPrice <= entryPricePlain
                    ? int256(uint256(netPnlPlain))
                    : -int256(uint256(netPnlPlain));
            }
        }

        if (signedPnl > 0) {
            vault.payTrader(trader, uint256(signedPnl), uint256(collateralPlain));
        } else {
            uint256 loss = uint256(-signedPnl);
            if (loss >= uint256(collateralPlain)) {
                vault.receiveLoss(uint256(collateralPlain));
            } else {
                uint256 remaining = uint256(collateralPlain) - loss;
                vault.receiveLoss(loss);
                vault.payTrader(trader, 0, remaining);
            }
        }

        fundingManager.decreaseOpenInterest(token, uint256(sizePlain), isLong);

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
    ) public view returns (euint128) {

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
    ) public view returns (euint128) {

        int256 currentFunding = fundingManager.getFundingRate(position.indexToken);
        int256 fundingDiff    = currentFunding - position.entryFundingRate;

        // Decrypt size only to compute the scalar fee — size alone does not
        // reveal direction or profitability
        uint128 sizePlain = FHE.decrypt(position.size);
        int256 feeBase    = (int256(uint256(sizePlain)) * fundingDiff) / int256(FUNDING_PRECISION);

        // Fee magnitude is always non-negative; re-encrypt for encrypted return
        uint256 feeMagnitude = feeBase >= 0 ? uint256(feeBase) : uint256(-feeBase);
        return FHE.asEuint128(feeMagnitude);
    }

    // =========================================================
    // LIQUIDATION
    // =========================================================

    function liquidate(
        address trader,
        address token,
        bool isLong
    ) external onlyLiquidationManager {

        bytes32 key = getPositionKey(trader, token, isLong);
        Position storage position = positions[key];
        require(position.exists, "no position");

        uint256 price = oracle.getPrice(token);

        euint128 ePnl        = calculatePnL(position, price);
        euint128 eFundingFee = calculateFundingFee(position);

        // Net PnL magnitude after fees
        ebool    feeExceedsPnl = FHE.gt(eFundingFee, ePnl);
        euint128 eNetPnl       = FHE.select(feeExceedsPnl, FHE.asEuint128(0), FHE.sub(ePnl, eFundingFee));

        // Decrypt at settlement boundary
        uint128 netPnlPlain     = FHE.decrypt(eNetPnl);
        uint128 collateralPlain = FHE.decrypt(position.collateral);
        uint128 sizePlain       = FHE.decrypt(position.size);
        bool    isLongPlain     = FHE.decrypt(position.isLong);
        uint128 entryPricePlain = FHE.decrypt(position.entryPrice);

        // Determine whether the position is at a loss
        bool atLoss;
        if (isLongPlain) {
            atLoss = price < entryPricePlain;
        } else {
            atLoss = price > entryPricePlain;
        }

        require(atLoss, "position is not at a loss");

        uint256 loss = uint256(netPnlPlain);

        require(
            loss * 100 / uint256(collateralPlain) >= LIQUIDATION_THRESHOLD,
            "not liquidatable"
        );

        vault.releaseLiquidity(uint256(sizePlain));

        uint256 reward = (uint256(collateralPlain) * 5) / 100;

        vault.receiveLoss(uint256(collateralPlain) - reward);
        vault.payTrader(msg.sender, 0, reward);

        fundingManager.decreaseOpenInterest(token, uint256(sizePlain), isLongPlain);

        delete positions[key];

        emit PositionLiquidated(trader, token);
    }
}
