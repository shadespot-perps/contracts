// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../core/PositionManager.sol";
import "../core/FHEVault.sol";
import "../core/FundingRateManager.sol";
import "./OrderManager.sol";
import "../tokens/IEncryptedERC20.sol";
import { FHE, euint64 } from "cofhe-contracts/FHE.sol";

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

    PositionManager    public positionManager;
    FHEVault           public vault;
    OrderManager       public orderManager;
    FundingRateManager public fundingManager;

    IEncryptedERC20 public collateralToken;

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
        vault           = FHEVault(_vault);
        orderManager    = OrderManager(_orderManager);
        fundingManager  = FundingRateManager(_fundingManager);
        collateralToken = IEncryptedERC20(_collateralToken);
        indexToken      = _indexToken;
        owner           = msg.sender;
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

    /**
     * @notice Phase 1 — submit the encrypted liquidity-check decrypt task so
     *         the CoFHE dispatcher can process it in a committed transaction.
     *
     *         Call this once before openPosition and wait for the dispatcher to
     *         publish the result (~15–30 s on live CoFHE networks).  openPosition
     *         will then find the pending result and succeed without reverting.
     *
     * @param token      Index token (must equal indexToken).
     * @param collateral Collateral amount (same value used in openPosition).
     * @param leverage   Leverage multiplier (same value used in openPosition).
     */
    function submitDecryptTaskForOpen(
        address token,
        uint256 collateral,
        uint256 leverage
    ) external {
        require(token == indexToken, "unsupported index token");
        vault.submitReserveLiquidityCheck(msg.sender, collateral * leverage);
    }

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
    ) external payable requireFee {
        require(collateral > 0, "invalid collateral");
        require(token == indexToken, "unsupported index token");

        fundingManager.updateFunding(token);

        // Confidential transfer: router (operator) moves collateral from trader → vault
        euint64 eCollateral = FHE.asEuint64(uint64(collateral));
        FHE.allow(eCollateral, address(collateralToken));
        collateralToken.confidentialTransferFrom(msg.sender, address(vault), eCollateral);

        positionManager.openPosition(msg.sender, token, collateral, leverage, isLong);

        emit OpenPosition(msg.sender, token, collateral, leverage, isLong);
    }

    // -------------------------------------------------
    // CLOSE POSITION
    // -------------------------------------------------

    function closePosition(address token, bool isLong) external payable requireFee {
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
    ) external payable requireFee {
        require(collateral > 0, "invalid collateral");
        require(token == indexToken, "unsupported index token");

        euint64 eCollateral = FHE.asEuint64(uint64(collateral));
        FHE.allow(eCollateral, address(collateralToken));
        collateralToken.confidentialTransferFrom(msg.sender, address(vault), eCollateral);

        orderManager.createOrder(msg.sender, token, collateral, leverage, triggerPrice, isLong);

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

        fundingManager.updateFunding(token);
        positionManager.openPosition(trader, token, collateral, leverage, isLong);

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
        collateralToken.confidentialTransferFrom(msg.sender, address(vault), eAmount);
        vault.deposit(msg.sender, amount);
        emit AddLiquidity(msg.sender, amount);
    }

    /**
     * @notice Phase 1 of remove liquidity: compute the encrypted share-to-token
     *         ratio and submit CoFHE decrypt tasks for balance and liquidity checks.
     *         Wait ~15–30 s for the dispatcher to publish results, then call
     *         removeLiquidity with the same shares value.
     * @param shares Plaintext share amount to redeem (visible in the LP's lpBalance).
     */
    function submitWithdrawCheck(uint256 shares) external {
        vault.submitWithdrawCheck(msg.sender, shares);
    }

    /**
     * @notice Phase 2 of remove liquidity: execute the withdrawal using pre-submitted
     *         decrypt results. The payout is sent as an encrypted euint64 transfer —
     *         the exact amount is never exposed on-chain.
     * @param shares Must match the value passed to submitWithdrawCheck.
     */
    function removeLiquidity(uint256 shares) external {
        vault.withdraw(msg.sender, shares);
        emit RemoveLiquidity(msg.sender, shares);
    }
}
