// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Vault is ERC20 {

    IERC20 public immutable collateralToken;

    address public positionManager;
    address public router;
    uint256 public totalLiquidity;
    uint256 public totalReserved;
    address public owner;

    event Deposit(address indexed lp, uint256 amount, uint256 shares);
    event Withdraw(address indexed lp, uint256 shares, uint256 amount);

    event IncreaseReserved(uint256 amount);
    event DecreaseReserved(uint256 amount);

    event PayOut(address indexed user, uint256 amount);
    event ReceiveLoss(uint256 amount);



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

    constructor(address _token, address _owner) ERC20("ShadeSpot LP", "SLP") {
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

    function deposit(address lp, uint256 amount) external onlyRouter {
        require(amount > 0, "Invalid amount");

        uint256 supply = totalSupply();
        uint256 shares = (supply == 0 || totalLiquidity == 0)
            ? amount
            : (amount * supply) / totalLiquidity;

        totalLiquidity += amount;
        _mint(lp, shares);

        emit Deposit(lp, amount, shares);
    }

    function withdraw(address lp, uint256 shares) external onlyRouter {
        require(balanceOf(lp) >= shares, "Insufficient shares");

        uint256 amount = (shares * totalLiquidity) / totalSupply();
        require(availableLiquidity() >= amount, "Liquidity locked");

        totalLiquidity -= amount;
        _burn(lp, shares);
        collateralToken.transfer(lp, amount);

        emit Withdraw(lp, shares, amount);
    }

    // ------------------------------------------------
    // POSITION MANAGER FUNCTIONS
    // ------------------------------------------------

    function reserveLiquidity(uint256 amount, address /* trader */)
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

    function payTrader(address user, uint256 profit, uint256 returnedCollateral)
        external
        onlyPositionManager
    {
        uint256 actualProfit = profit;
        if (profit > 0) {
            uint256 available = availableLiquidity();
            if (profit > available) {
                actualProfit = available;
            }
            totalLiquidity -= actualProfit;
        }
        
        uint256 amount = actualProfit + returnedCollateral;
        collateralToken.transfer(user, amount);

        emit PayOut(user, amount);
    }

    function refundCollateral(address user, uint256 amount) external onlyRouter {
        collateralToken.transfer(user, amount);
    }

    function receiveLoss(uint256 amount)
        external
        onlyPositionManager
    {

        totalLiquidity += amount;

        emit ReceiveLoss(amount);
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