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

    event LiquidationExecuted(
        address indexed trader,
        address indexed liquidator,
        address indexed token
    );

    constructor(
        address _positionManager,
        address _fundingManager
    ) {
        positionManager = PositionManager(_positionManager);
        fundingManager = FundingRateManager(_fundingManager);
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
    ) external {
        // Best-effort funding settlement before the liquidation check
        fundingManager.updateFunding(token);

        positionManager.liquidate(trader, token, isLong);

        emit LiquidationExecuted(trader, msg.sender, token);
    }
}
