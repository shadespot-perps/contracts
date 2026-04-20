// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/PositionManager.sol";

/**
 * @title LiquidationManager
 * @notice Entry point for liquidation requests and finalization.
 */
contract LiquidationManager {

    PositionManager public positionManager;
    FHEFundingRateManager public fundingManager;

    address public owner;

    /// @notice Tracks the liquidator authorized to finalize each request.
    mapping(bytes32 => address) public pendingLiquidator;

    event LiquidationExecuted(
        bytes32 indexed positionId,
        address indexed liquidator,
        address indexed token
    );
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

    function requestLiquidation(bytes32 positionId, address token) public {
        fundingManager.updateFunding(token);

        pendingLiquidator[positionId] = msg.sender;
        positionManager.requestLiquidationCheck(positionId, msg.sender);
        emit LiquidationExecuted(positionId, msg.sender, token);
    }

    /// @notice Finalizes liquidation after decrypt proofs are available.
    /// @param positionKey  Position identifier.
    /// @param canLiquidatePlain  Decrypted canLiquidate boolean.
    /// @param canLiquidateSignature  CoFHE proof for canLiquidate.
    /// @param collateralPlain  Decrypted collateral amount.
    /// @param collateralSignature  CoFHE proof for collateral.
    /// @param sizePlain  Decrypted size amount.
    /// @param sizeSignature  CoFHE proof for size.
    /// @param isLongPlain  Decrypted direction (legacy param, deprecated).
    function finalizeLiquidationRequest(
        bytes32 positionKey,
        bool canLiquidatePlain,
        bytes calldata canLiquidateSignature,
        uint256 collateralPlain,
        bytes calldata collateralSignature,
        uint256 sizePlain,
        bytes calldata sizeSignature,
        bool isLongPlain
    ) public {
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

    // Backward-compatible aliases for existing integrations.
    function liquidate(bytes32 positionId, address token) external {
        requestLiquidation(positionId, token);
    }

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
        finalizeLiquidationRequest(
            positionKey,
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
