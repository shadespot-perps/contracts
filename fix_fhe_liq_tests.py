with open('test/unit/FHEPool.t.sol', 'r') as f:
    content = f.read()

# Replace old 9-arg finalizeLiquidation(trader, ethToken, true, ...) with new positionKey-based (8-arg)
old_blocks = [
    # test_FHERouter_Liquidation_LiquidatorReceivesReward
    """        lm.finalizeLiquidation(
            trader,
            ethToken,
            true,
            true,
            "",
            uint256(COLLATERAL),
            "",
            uint256(COLLATERAL) * uint256(bigLeverage),
            ""
        );""",
    # test_FHERouter_Liquidation_PositionDeleted
    """        lm.finalizeLiquidation(
            trader,
            ethToken,
            true,
            true,
            "",
            uint256(COLLATERAL),
            "",
            uint256(COLLATERAL) * uint256(bigLeverage),
            ""
        );""",
    # test_FHERouter_Liquidation_NotLiquidatable_Reverts
    """        lm.finalizeLiquidation(
            trader,
            ethToken,
            true,
            false,
            "",
            uint256(COLLATERAL),
            "",
            uint256(COLLATERAL) * uint256(LEVERAGE),
            ""
        );""",
]

new_blocks = [
    # Reward test
    """        lm.finalizeLiquidation(
            lastPosId,
            true,
            "",
            uint256(COLLATERAL),
            "",
            uint256(COLLATERAL) * uint256(bigLeverage),
            "",
            true
        );""",
    # Deleted test
    """        lm.finalizeLiquidation(
            lastPosId,
            true,
            "",
            uint256(COLLATERAL),
            "",
            uint256(COLLATERAL) * uint256(bigLeverage),
            "",
            true
        );""",
    # Not-liquidatable test
    """        lm.finalizeLiquidation(
            lastPosId,
            false,
            "",
            uint256(COLLATERAL),
            "",
            uint256(COLLATERAL) * uint256(LEVERAGE),
            "",
            true
        );""",
]

for old, new in zip(old_blocks, new_blocks):
    if old in content:
        content = content.replace(old, new, 1)
    else:
        print(f"NOT FOUND:\n{old[:80]}")

with open('test/unit/FHEPool.t.sol', 'w') as f:
    f.write(content)

print("Done")
