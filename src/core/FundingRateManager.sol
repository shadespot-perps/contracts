// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract FundingRateManager {

    uint256 public constant FUNDING_INTERVAL = 1 hours;
    uint256 public constant FUNDING_RATE_PRECISION = 1e12;

    address public owner;
    address public router;
    address public positionManager;

    struct FundingData {
        uint256 cumulativeFundingRate;
        uint256 lastFundingTime;
        uint256 longOpenInterest;
        uint256 shortOpenInterest;
    }

    mapping(address => FundingData) public fundingData;

    event FundingUpdated(
        address indexed token,
        uint256 fundingRate,
        uint256 cumulativeFundingRate
    );

    event OpenInterestUpdated(
        address indexed token,
        uint256 longOpenInterest,
        uint256 shortOpenInterest
    );

    event RouterSet(address router);
    event PositionManagerSet(address positionManager);

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

    modifier onlyPositionManager() {
        require(msg.sender == positionManager, "only position manager");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // -------------------------------------------------
    // ADMIN CONFIG
    // -------------------------------------------------

    function setRouter(address _router) external onlyOwner {
        require(router == address(0), "router already set");
        router = _router;
        emit RouterSet(_router);
    }

    function setPositionManager(address _pm) external onlyOwner {
        require(positionManager == address(0), "pm already set");
        positionManager = _pm;
        emit PositionManagerSet(_pm);
    }

    // -------------------------------------------------
    // UPDATE OPEN INTEREST (PositionManager only)
    // -------------------------------------------------

    function increaseOpenInterest(
        address token,
        uint256 size,
        bool isLong
    ) external onlyPositionManager {

        FundingData storage data = fundingData[token];

        if (isLong) {
            data.longOpenInterest += size;
        } else {
            data.shortOpenInterest += size;
        }

        emit OpenInterestUpdated(
            token,
            data.longOpenInterest,
            data.shortOpenInterest
        );
    }

    function decreaseOpenInterest(
        address token,
        uint256 size,
        bool isLong
    ) external onlyPositionManager {

        FundingData storage data = fundingData[token];

        if (isLong) {
            data.longOpenInterest -= size;
        } else {
            data.shortOpenInterest -= size;
        }

        emit OpenInterestUpdated(
            token,
            data.longOpenInterest,
            data.shortOpenInterest
        );
    }

    // -------------------------------------------------
    // UPDATE FUNDING (Router only)
    // -------------------------------------------------

    function updateFunding(address token) external onlyRouter {

        FundingData storage data = fundingData[token];

        if (block.timestamp < data.lastFundingTime + FUNDING_INTERVAL) {
            return;
        }

        uint256 longOI = data.longOpenInterest;
        uint256 shortOI = data.shortOpenInterest;

        if (longOI == 0 && shortOI == 0) {
            data.lastFundingTime = block.timestamp;
            return;
        }

        uint256 imbalance;

        if (longOI > shortOI) {
            imbalance = longOI - shortOI;
        } else {
            imbalance = shortOI - longOI;
        }

        uint256 totalOI = longOI + shortOI;

        uint256 fundingRate =
            (imbalance * FUNDING_RATE_PRECISION) / totalOI;

        data.cumulativeFundingRate += fundingRate;
        data.lastFundingTime = block.timestamp;

        emit FundingUpdated(
            token,
            fundingRate,
            data.cumulativeFundingRate
        );
    }

    // -------------------------------------------------
    // VIEW FUNCTIONS
    // -------------------------------------------------

    function getFundingRate(address token)
        external
        view
        returns (uint256)
    {
        return fundingData[token].cumulativeFundingRate;
    }

    function getOpenInterest(address token)
        external
        view
        returns (uint256 longOI, uint256 shortOI)
    {
        FundingData storage data = fundingData[token];

        return (
            data.longOpenInterest,
            data.shortOpenInterest
        );
    }
}