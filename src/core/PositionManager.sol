// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Vault.sol";
import "../oracle/PriceOracle.sol";
import "./FundingRateManager.sol";

contract PositionManager {

    struct Position {
        address owner;
        address indexToken;
        uint256 size;
        uint256 collateral;
        uint256 entryPrice;
        uint256 entryFundingRate;
        bool isLong;
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

    event PositionOpened(
        address trader,
        address token,
        uint256 size,
        uint256 collateral,
        bool isLong
    );

    event PositionClosed(
        address trader,
        address token,
        int256 pnl
    );

    event PositionLiquidated(
        address trader,
        address token
    );

    constructor(
        address _vault,
        address _oracle,
        address _fundingManager
    ) {
        vault = Vault(_vault);
        oracle = PriceOracle(_oracle);
        fundingManager = FundingRateManager(_fundingManager);
        owner = msg.sender;
    }

    // -------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------

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

    // -------------------------------------------------
    // ADMIN
    // -------------------------------------------------

    function setRouter(address _router) external onlyOwner {
        router = _router;
    }

    function setLiquidationManager(address _liq)
        external
        onlyOwner
    {
        liquidationManager = _liq;
    }

    // -------------------------------------------------
    // POSITION KEY
    // -------------------------------------------------

    function getPositionKey(
        address trader,
        address token,
        bool isLong
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(trader, token, isLong));
    }

    function getPosition(bytes32 key)
        external
        view
        returns (Position memory)
    {
        return positions[key];
    }

    // -------------------------------------------------
    // OPEN POSITION
    // -------------------------------------------------

    function openPosition(
        address trader,
        address token,
        uint256 collateral,
        uint256 leverage,
        bool isLong
    ) external onlyRouter {

        require(leverage <= MAX_LEVERAGE, "exceeds max leverage");
        require(collateral > 0, "invalid collateral");

        uint256 size = collateral * leverage;
        uint256 price = oracle.getPrice(token);

        bytes32 key = getPositionKey(trader, token, isLong);
        require(positions[key].size == 0, "position exists");

        uint256 fundingRate = fundingManager.getFundingRate(token);

        vault.reserveLiquidity(size);

        positions[key] = Position({
            owner: trader,
            indexToken: token,
            size: size,
            collateral: collateral,
            entryPrice: price,
            entryFundingRate: fundingRate,
            isLong: isLong
        });

        fundingManager.increaseOpenInterest(token, size, isLong);

        emit PositionOpened(trader, token, size, collateral, isLong);
    }

    // -------------------------------------------------
    // CLOSE POSITION
    // -------------------------------------------------

    function closePosition(
        address trader,
        address token,
        bool isLong
    ) external onlyRouter {

        bytes32 key = getPositionKey(trader, token, isLong);

        Position storage position = positions[key];
        require(position.size > 0, "no position");

        uint256 price = oracle.getPrice(token);

        int256 pnl = calculatePnL(position, price);

        int256 fundingFee = calculateFundingFee(position);

        pnl -= fundingFee;

        vault.releaseLiquidity(position.size);

        if (pnl > 0) {

            uint256 profit = uint256(pnl);
            vault.payout(trader, profit + position.collateral);

        } else {

            uint256 loss = uint256(-pnl);

            if (loss >= position.collateral) {
                vault.receiveLoss(position.collateral);
            } else {
                uint256 remaining = position.collateral - loss;
                vault.receiveLoss(loss);
                vault.payout(trader, remaining);
            }
        }

        fundingManager.decreaseOpenInterest(
            token,
            position.size,
            position.isLong
        );

        delete positions[key];

        emit PositionClosed(trader, token, pnl);
    }

    // -------------------------------------------------
    // PNL
    // -------------------------------------------------

    function calculatePnL(
        Position memory position,
        uint256 price
    ) public pure returns (int256) {

        if (position.isLong) {

            int256 diff = int256(price) - int256(position.entryPrice);
            return (diff * int256(position.size)) /
                int256(position.entryPrice);

        } else {

            int256 diff = int256(position.entryPrice) - int256(price);
            return (diff * int256(position.size)) /
                int256(position.entryPrice);
        }
    }

    // -------------------------------------------------
    // FUNDING FEE
    // -------------------------------------------------

    function calculateFundingFee(
        Position memory position
    ) public view returns (int256) {

        uint256 currentFunding =
            fundingManager.getFundingRate(position.indexToken);

        uint256 fundingDiff =
            currentFunding - position.entryFundingRate;

        return int256(
            (position.size * fundingDiff) / FUNDING_PRECISION
        );
    }

    // -------------------------------------------------
    // LIQUIDATION
    // -------------------------------------------------

    function liquidate(
        address trader,
        address token,
        bool isLong
    ) external onlyLiquidationManager {

        bytes32 key = getPositionKey(trader, token, isLong);

        Position storage position = positions[key];

        require(position.size > 0, "no position");

        uint256 price = oracle.getPrice(token);

        int256 pnl = calculatePnL(position, price);

        int256 fundingFee = calculateFundingFee(position);

        pnl -= fundingFee;

        if (pnl < 0) {

            uint256 loss = uint256(-pnl);

            require(
                loss * 100 / position.collateral >=
                    LIQUIDATION_THRESHOLD,
                "not liquidatable"
            );

            vault.releaseLiquidity(position.size);
            vault.receiveLoss(position.collateral);

            fundingManager.decreaseOpenInterest(
                token,
                position.size,
                position.isLong
            );

            delete positions[key];

            emit PositionLiquidated(trader, token);
        }
    }
}