// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/PositionManager.sol";

/**
 * @title LiquidationManager
 * @notice Thin entrypoint for liquidators. All PnL math, encrypted threshold checks,
 *         and vault settlement live in PositionManager — this contract just triggers them.
 *
Privacy guarantees (inherited from PositionManager.liquidate):
 *   - PnL and funding fee are computed entirely in the FHE domain.
 *   - Only a single bit (canLiquidate: yes/no) is decrypted to authorise execution.
 *   - Only the final settlement amounts are decrypted, exclusively to move tokens.
 */
contract LiquidationManager {

    PositionManager public positionManager;
    FHEFundingRateManager public fundingManager;

    address public owner;
    /// @notice ETH fee required to call liquidate.
    uint256 public liquidationFee;
    uint256 public collectedFees;

    // Binds the liquidator who paid the fee to the finalize step, preventing reward theft.
    mapping(bytes32 => address) public pendingLiquidator;

    event LiquidationExecuted(
        bytes32 indexed positionId,
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
        fundingManager = FHEFundingRateManager(_fundingManager);
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

    function liquidate(bytes32 positionId, address token) external payable {
        require(msg.value >= liquidationFee, "Insufficient ETH fee");
        collectedFees += msg.value;

        // Best-effort funding settlement before the liquidation check
        fundingManager.updateFunding(token);

        pendingLiquidator[positionId] = msg.sender;
        positionManager.liquidate(positionId, msg.sender);
        emit LiquidationExecuted(positionId, msg.sender, token);
    }

    // -------------------------------------------------------
    // FINALIZE LIQUIDATION (decrypt-with-proof)
    // -------------------------------------------------------

    /// @notice Called by the off-chain keeper after decrypting the FHE handles.
    /// @param positionKey  The position identifier (bytes32).
    /// @param canLiquidatePlain  Decrypted canLiquidate boolean.
    /// @param canLiquidateSignature  CoFHE proof for canLiquidate.
    /// @param collateralPlain  Decrypted collateral amount.
    /// @param collateralSignature  CoFHE proof for collateral.
    /// @param sizePlain  Decrypted size amount.
    /// @param sizeSignature  CoFHE proof for size.
    /// @param isLongPlain  Decrypted direction (legacy param, deprecated).
    function finalizeLiquidation(
        bytes32 positionKey,
        bool canLiquidatePlain,
        bytes calldata canLiquidateSignature,
        uint256 collateralPlain,
        bytes calldata collateralSignature,
        uint256 sizePlain,
        bytes calldata sizeSignature,
        bool isLongPlain
    ) external {
        address liquidator = pendingLiquidator[positionKey];
        require(liquidator != address(0), "no pending liquidation");
        delete pendingLiquidator[positionKey];

        positionManager.finalizeLiquidation(
            positionKey,
            liquidator,
            canLiquidatePlain,
            canLiquidateSignature,
            collateralPlain,
            collateralSignature,
            sizePlain,
            sizeSignature,
            isLongPlain
        );
    }
}
