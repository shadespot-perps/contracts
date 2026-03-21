// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Vault {

    IERC20 public immutable collateralToken;

    address public positionManager;
    address public router;
    uint256 public totalLiquidity;
    uint256 public totalReserved;
    address public owner;

    mapping(address => uint256) public lpBalance;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    event IncreaseReserved(uint256 amount);
    event DecreaseReserved(uint256 amount);

    event PayOut(address indexed user, uint256 amount);
    event ReceiveLoss(uint256 amount);

    event ReceiveFunding(uint256 amount);
    event PayFunding(address indexed trader, uint256 amount);

    modifier onlyPositionManager() {
        require(msg.sender == positionManager, "Not position manager");
        _;
    }

    modifier onlyRouter() {
        require(msg.sender == router, "Not router");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _token, address _owner) {
        collateralToken = IERC20(_token);
        owner = _owner;
    }

    function setPositionManager(address _pm) external onlyOwner {
        require(positionManager == address(0), "Already set");
        positionManager = _pm;
    }


function setRouter(address _router) external onlyOwner {
        require(router == address(0), "Already set");
        router = _router;
    }

    // ------------------------------------------------
    // LP FUNCTIONS
    // ------------------------------------------------

    function deposit(uint256 amount) external onlyRouter{

        require(amount > 0, "Invalid amount");

        collateralToken.transferFrom(
            msg.sender,
            address(this),
            amount
        );

        lpBalance[msg.sender] += amount;
        totalLiquidity += amount;

        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external onlyRouter {

        require(lpBalance[msg.sender] >= amount, "Insufficient balance");
        require(availableLiquidity() >= amount, "Liquidity locked");

        lpBalance[msg.sender] -= amount;
        totalLiquidity -= amount;

        collateralToken.transfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    // ------------------------------------------------
    // POSITION MANAGER FUNCTIONS
    // ------------------------------------------------

    function reserveLiquidity(uint256 amount)
        external
        onlyPositionManager
    {

        require(
            availableLiquidity() >= amount,
            "Insufficient vault liquidity"
        );

        totalReserved += amount;

        emit IncreaseReserved(amount);
    }

    function releaseLiquidity(uint256 amount)
        external
        onlyPositionManager
    {

        require(totalReserved >= amount, "Invalid release");

        totalReserved -= amount;

        emit DecreaseReserved(amount);
    }

    function payout(address user, uint256 amount)
        external
        onlyPositionManager
    {

        require(
            availableLiquidity() >= amount,
            "Vault insufficient"
        );

        collateralToken.transfer(user, amount);

        emit PayOut(user, amount);
    }

    function receiveLoss(uint256 amount)
        external
        onlyPositionManager
    {

        totalLiquidity += amount;

        emit ReceiveLoss(amount);
    }

    // ------------------------------------------------
    // FUNDING FUNCTIONS
    // ------------------------------------------------

    // trader pays funding → LP profit
    function receiveFunding(uint256 amount)
        external
        onlyPositionManager
    {

        totalLiquidity += amount;

        emit ReceiveFunding(amount);
    }

    // trader receives funding → LP pays
    function payFunding(address trader, uint256 amount)
        external
        onlyPositionManager
    {

        require(
            availableLiquidity() >= amount,
            "Insufficient funding liquidity"
        );

        collateralToken.transfer(trader, amount);

        emit PayFunding(trader, amount);
    }

    // ------------------------------------------------
    // VIEW FUNCTIONS
    // ------------------------------------------------

    function availableLiquidity()
        public
        view
        returns (uint256)
    {
        return totalLiquidity - totalReserved;
    }
}