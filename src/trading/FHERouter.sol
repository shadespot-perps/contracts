// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../core/PositionManager.sol";
import "../core/FHEVault.sol";
import "../core/FundingRateManager.sol";
import "./OrderManager.sol";
import "../tokens/IEncryptedERC20.sol";
import {FHE, euint64} from "cofhe-contracts/FHE.sol";

/**
 * @title FHERouter
 * @notice Pool 2 entry point — collateral is a Fhenix FHERC20 token.
 *
 * Key differences from Router (Pool 1):
 *   - collateralToken is IEncryptedERC20 (Fhenix FHERC20 with encrypted balances).
 *   - Token transfers use confidentialTransferFrom instead of transferFrom.
 *   - Instead of approve, users must call:
 *       fheToken.setOperator(address(fheRouter), untilTimestamp)
 *     once before their first trade or liquidity deposit.
 *   - vault is FHEVault (LP balances and pool counters stored as euint64 ciphertexts).
 *   - indexToken is enforced — only ETH positions are accepted.
 */
contract FHERouter {
    PositionManager public positionManager;
    FHEVault public vault;
    OrderManager public orderManager;
    FundingRateManager public fundingManager;

    IEncryptedERC20 public collateralToken;

    /// @notice The only token that can be used as a trade (index) token in this pool.
    address public immutable indexToken;

    event OpenPosition(
        address indexed trader,
        address token,
        uint256 collateral,
        uint256 leverage,
        bool isLong
    );

    event ClosePosition(address indexed trader, address token, bool isLong);

    event OrderCreated(address indexed trader, address token);

    event OrderExecuted(uint256 orderId);

    event AddLiquidity(address indexed user, uint256 amount);
    event RemoveLiquidity(address indexed user, uint256 amount);

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
        vault = FHEVault(_vault);
        orderManager = OrderManager(_orderManager);
        fundingManager = FundingRateManager(_fundingManager);
        collateralToken = IEncryptedERC20(_collateralToken);
        indexToken = _indexToken;
    }

    // -------------------------------------------------
    // MARKET ORDER (OPEN POSITION)
    // -------------------------------------------------

    /**
     * @notice Open a leveraged position using FHE token as collateral.
     * @dev Caller must have granted this router operator status on the FHE token:
     *      fheToken.setOperator(address(fheRouter), untilTimestamp)
     */
    function openPosition(
        address token,
        uint256 collateral,
        uint256 leverage,
        bool isLong
    ) external {
        require(collateral > 0, "invalid collateral");
        require(token == indexToken, "unsupported index token");

        fundingManager.updateFunding(token);

        // Confidential transfer: router (operator) moves collateral from trader → vault
        euint64 eCollateral = FHE.asEuint64(uint64(collateral));
        FHE.allow(eCollateral, address(collateralToken));
        collateralToken.confidentialTransferFrom(
            msg.sender,
            address(vault),
            eCollateral
        );

        positionManager.openPosition(
            msg.sender,
            token,
            collateral,
            leverage,
            isLong
        );

        emit OpenPosition(msg.sender, token, collateral, leverage, isLong);
    }

    // -------------------------------------------------
    // CLOSE POSITION
    // -------------------------------------------------

    function closePosition(address token, bool isLong) external {
        fundingManager.updateFunding(token);
        positionManager.requestClosePosition(msg.sender, token, isLong);
        emit ClosePosition(msg.sender, token, isLong);
    }

    // -------------------------------------------------
    // CREATE LIMIT ORDER
    // -------------------------------------------------

    /**
     * @notice Create a limit/trigger order using FHE token collateral.
     * @dev Caller must have granted this router operator status on the FHE token.
     */
    function createOrder(
        address token,
        uint256 collateral,
        uint256 leverage,
        uint256 triggerPrice,
        bool isLong
    ) external {
        require(collateral > 0, "invalid collateral");
        require(token == indexToken, "unsupported index token");

        euint64 eCollateral = FHE.asEuint64(uint64(collateral));
        FHE.allow(eCollateral, address(collateralToken));
        collateralToken.confidentialTransferFrom(
            msg.sender,
            address(vault),
            eCollateral
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
        (address trader, , uint256 collateral, , , ) = orderManager
            .getOrderMeta(orderId);
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

    /**
     * @notice Add liquidity to Pool 2 vault using FHE token.
     * @dev Caller must have granted this router operator status on the FHE token.
     */
    function addLiquidity(uint256 amount) external {
        euint64 eAmount = FHE.asEuint64(uint64(amount));
        FHE.allow(eAmount, address(collateralToken));
        collateralToken.confidentialTransferFrom(
            msg.sender,
            address(vault),
            eAmount
        );
        vault.deposit(amount);
        emit AddLiquidity(msg.sender, amount);
    }

    function removeLiquidity(uint256 amount) external {
        vault.withdraw(amount);
        emit RemoveLiquidity(msg.sender, amount);
    }
}
