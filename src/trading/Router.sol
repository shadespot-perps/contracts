// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/PositionManager.sol";
import "../core/Vault.sol";
import "../core/FundingRateManager.sol";
import "./OrderManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Router {

    PositionManager public positionManager;
    Vault public vault;
    OrderManager public orderManager;
    FundingRateManager public fundingManager;

    IERC20 public collateralToken;

    /// @notice The only token that can be used as a trade (index) token in this pool.
    address public immutable indexToken;

    address public owner;
    /// @notice ETH fee required for each trading action (open, close, order, liquidate).
    uint256 public actionFee;
    uint256 public collectedFees;

    event OpenPosition(
        address indexed trader,
        address token,
        uint256 collateral,
        uint256 leverage,
        bool isLong
    );

    event ClosePosition(
        address indexed trader,
        address token,
        bool isLong
    );

    event OrderCreated(
        address indexed trader,
        address         token
        // triggerPrice intentionally omitted — stored encrypted in OrderManager
    );

    event OrderExecuted(uint256 orderId);

    event AddLiquidity(address indexed user, uint256 amount);
    event RemoveLiquidity(address indexed user, uint256 amount);

    event ActionFeeSet(uint256 newFee);
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier requireFee() {
        require(msg.value >= actionFee, "Insufficient ETH fee");
        collectedFees += msg.value;
        _;
    }

    constructor(
        address _positionManager,
        address _vault,
        address _orderManager,
        address _fundingManager,
        address _collateralToken,
        address _indexToken
    ) {
        require(_indexToken != address(0), "invalid index token");
        positionManager = PositionManager(_positionManager);
        vault = Vault(_vault);
        orderManager = OrderManager(_orderManager);
        fundingManager = FundingRateManager(_fundingManager);
        collateralToken = IERC20(_collateralToken);
        indexToken = _indexToken;
        owner = msg.sender;
    }

    function setActionFee(uint256 _fee) external onlyOwner {
        actionFee = _fee;
        emit ActionFeeSet(_fee);
    }

    function withdrawFees(address payable recipient) external onlyOwner {
        uint256 amount = collectedFees;
        collectedFees = 0;
        (bool ok, ) = recipient.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit FeesWithdrawn(recipient, amount);
    }

    // -------------------------------------------------
    // MARKET ORDER (OPEN POSITION)
    // -------------------------------------------------

    function openPosition(
        address token,
        uint256 collateral,
        uint256 leverage,
        bool isLong
    ) external payable requireFee {

        require(collateral > 0, "invalid collateral");
        require(token == indexToken, "unsupported index token");

        // update funding before opening
        fundingManager.updateFunding(token);

        // transfer collateral
        collateralToken.transferFrom(
            msg.sender,
            address(vault),
            collateral
        );

        positionManager.openPosition(
            msg.sender,
            token,
            collateral,
            leverage,
            isLong
        );

        emit OpenPosition(
            msg.sender,
            token,
            collateral,
            leverage,
            isLong
        );
    }

    // -------------------------------------------------
    // CLOSE POSITION
    // -------------------------------------------------

    function closePosition(
        address token,
        bool isLong
    ) external payable requireFee {

        // update funding before closing
        fundingManager.updateFunding(token);

        positionManager.requestClosePosition(
            msg.sender,
            token,
            isLong
        );

        emit ClosePosition(msg.sender, token, isLong);
    }

    // -------------------------------------------------
    // CREATE LIMIT ORDER
    // -------------------------------------------------

    function createOrder(
        address token,
        uint256 collateral,
        uint256 leverage,
        uint256 triggerPrice,
        bool isLong
    ) external payable requireFee {

        require(collateral > 0, "invalid collateral");
        require(token == indexToken, "unsupported index token");

        collateralToken.transferFrom(
            msg.sender,
            address(vault),
            collateral
        );

        orderManager.createOrder(
            msg.sender,
            token,
            collateral,
            leverage,
            triggerPrice,
            isLong
        );

        emit OrderCreated(msg.sender, token);
    }

    // -------------------------------------------------
    // CANCEL ORDER
    // -------------------------------------------------

    function cancelOrder(uint256 orderId) external {
        (address trader, , uint256 collateral, , , ) = orderManager.getOrderMeta(orderId);
        orderManager.cancelOrder(orderId, msg.sender);
        vault.refundCollateral(trader, collateral);
    }

    // -------------------------------------------------
    // EXECUTE ORDER (KEEPERS)
    // -------------------------------------------------

    function executeOrder(uint256 orderId) external {

        (
            address trader,
            address token,
            uint256 collateral,
            uint256 leverage,
            bool isLong
        ) = orderManager.executeOrder(orderId);

        // update funding before executing
        fundingManager.updateFunding(token);

        positionManager.openPosition(
            trader,
            token,
            collateral,
            leverage,
            isLong
        );

        emit OrderExecuted(orderId);
    }

    // -------------------------------------------------
    // LIQUIDITY FUNCTIONS
    // -------------------------------------------------

    function addLiquidity(uint256 amount) external {

        collateralToken.transferFrom(
            msg.sender,
            address(vault),
            amount
        );

        vault.deposit(amount);

        emit AddLiquidity(msg.sender, amount);
    }

    function removeLiquidity(uint256 amount) external {

        vault.withdraw(amount);

        emit RemoveLiquidity(msg.sender, amount);
    }
}