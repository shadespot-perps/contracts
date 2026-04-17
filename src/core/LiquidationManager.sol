// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/PositionManager.sol";
import "../core/FundingRateManager.sol";

/**
 * @title LiquidationManager
 * @notice Thin entrypoint for liquidators. All PnL math, encrypted threshold checks,
 *         and vault settlement live in PositionManager — this contract just triggers them.
 *
 * Privacy guarantees (inherited from PositionManager.liquidate):
 *   - PnL and funding fee are computed entirely in the FHE domain.
 *   - Only a single bit (canLiquidate: yes/no) is decrypted to authorise execution.
 *   - Only the final settlement amounts are decrypted, exclusively to move tokens.
 */
contract LiquidationManager {

    PositionManager public positionManager;
    FundingRateManager public fundingManager;

    address public owner;
    /// @notice ETH fee required to call liquidate.
    uint256 public liquidationFee;
    uint256 public collectedFees;

    event LiquidationExecuted(
        address indexed trader,
        address indexed liquidator,
        address indexed token
    );
    event LiquidationFeeSet(uint256 newFee);
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(
        address _positionManager,
        address _fundingManager
    ) {
        positionManager = PositionManager(_positionManager);
        fundingManager = FundingRateManager(_fundingManager);
        owner = msg.sender;
    }

    function setLiquidationFee(uint256 _fee) external onlyOwner {
        liquidationFee = _fee;
        emit LiquidationFeeSet(_fee);
    }

    function withdrawFees(address payable recipient) external onlyOwner {
        uint256 amount = collectedFees;
        collectedFees = 0;
        (bool ok, ) = recipient.call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit FeesWithdrawn(recipient, amount);
    }

    // -------------------------------------------------------
    // LIQUIDATE
    // -------------------------------------------------------
    // Flow:
    //   1. Attempt to settle any pending encrypted funding update.
    //   2. Delegate entirely to PositionManager, which:
    //        a. Computes PnL + funding fee in FHE (no plaintext).
    //        b. Decrypts one bool (canLiquidate).
    //        c. Decrypts settlement amounts and pays the liquidator reward.
    //        d. Cleans up position state.
    // -------------------------------------------------------

    function liquidate(
        address trader,
        address token,
        bool isLong
    ) external payable {
        require(msg.value >= liquidationFee, "Insufficient ETH fee");
        collectedFees += msg.value;

        // Best-effort funding settlement before the liquidation check
        fundingManager.updateFunding(token);

        positionManager.liquidate(trader, token, isLong, msg.sender);

        emit LiquidationExecuted(trader, msg.sender, token);
    }

    // -------------------------------------------------------
    // FINALIZE LIQUIDATION (decrypt-with-proof)
    // -------------------------------------------------------
    function finalizeLiquidation(
        address trader,
        address token,
        bool isLong,
        bool canLiquidatePlain,
        bytes calldata canLiquidateSignature,
        uint256 collateralPlain,
        bytes calldata collateralSignature,
        uint256 sizePlain,
        bytes calldata sizeSignature
    ) external {
        positionManager.finalizeLiquidation(
            trader,
            token,
            isLong,
            msg.sender,
            canLiquidatePlain,
            canLiquidateSignature,
            collateralPlain,
            collateralSignature,
            sizePlain,
            sizeSignature
        );
    }
}
