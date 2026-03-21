// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract PriceOracle {

    address public owner;

    struct PriceData {
        uint256 price;
        uint256 lastUpdated;
    }

    mapping(address => PriceData) public prices;

    uint256 public constant MAX_PRICE_DELAY = 5 minutes;

    event PriceUpdated(
        address indexed token,
        uint256 price,
        uint256 timestamp
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // ---------------------------------
    // SET PRICE (SIMULATED ORACLE)
    // ---------------------------------

    function setPrice(address token, uint256 price)
        external
        onlyOwner
    {
        require(price > 0, "invalid price");

        prices[token] = PriceData({
            price: price,
            lastUpdated: block.timestamp
        });

        emit PriceUpdated(token, price, block.timestamp);
    }

    // ---------------------------------
    // GET PRICE
    // ---------------------------------

    function getPrice(address token)
        external
        view
        returns (uint256)
    {

        PriceData memory data = prices[token];

        require(data.price > 0, "price not set");

        require(
            block.timestamp <= data.lastUpdated + MAX_PRICE_DELAY,
            "stale price"
        );

        return data.price;
    }

    // ---------------------------------
    // GET PRICE WITH TIMESTAMP
    // ---------------------------------

    function getPriceData(address token)
        external
        view
        returns (uint256 price, uint256 lastUpdated)
    {
        PriceData memory data = prices[token];
        return (data.price, data.lastUpdated);
    }
}