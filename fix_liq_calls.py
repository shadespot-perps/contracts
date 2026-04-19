import re

# Fix FHEPool.t.sol
with open('test/unit/FHEPool.t.sol', 'r') as f:
    text = f.read()

text = text.replace(
    'lm.liquidate(trader, ethToken, true);',
    'lm.liquidate(lastPosId, ethToken);'
)
with open('test/unit/FHEPool.t.sol', 'w') as f:
    f.write(text)

# Fix LiquidationManager.t.sol
with open('test/unit/LiquidationManager.t.sol', 'r') as f:
    text = f.read()

text = re.sub(
    r'lm\.liquidate\(trader, token, isLong\);\n\s*bytes32 liqKey = pm\.getTraderPositionKey\(trader, token, isLong\);',
    r'bytes32 liqKey = pm.getTraderPositionKey(trader, token, isLong);\n        lm.liquidate(liqKey, token);',
    text
)
# We also have lm.liquidate{value: fee}(trader, token, isLong)
text = re.sub(
    r'lm\.liquidate\{value: fee\}\(trader, token, isLong\);',
    r'bytes32 liqKey = pm.getTraderPositionKey(trader, token, isLong);\n        lm.liquidate{value: fee}(liqKey, token);',
    text
)
# For the one expecting revert:
text = re.sub(
    r'vm\.expectRevert\("Insufficient ETH fee"\);\n\s*lm\.liquidate\(trader, token, isLong\);',
    r'bytes32 liqKey0 = pm.getTraderPositionKey(trader, token, isLong);\n        vm.expectRevert("Insufficient ETH fee");\n        lm.liquidate(liqKey0, token);',
    text
)

with open('test/unit/LiquidationManager.t.sol', 'w') as f:
    f.write(text)

# Fix UserFlow.t.sol
with open('test/integration/UserFlow.t.sol', 'r') as f:
    text = f.read()

text = re.sub(
    r'liquidationManager\.liquidate\(trader, token, true\);\n\s*// Finalize liquidation with proof \(MockTaskManager accepts any signature\)\.\n\s*// Collateral=1000, size=10000\.\n\s*bytes32 liqKey = positionManager\.getTraderPositionKey\(trader, token, true\);',
    r'bytes32 liqKey = positionManager.getTraderPositionKey(trader, token, true);\n        liquidationManager.liquidate(liqKey, token);\n        // Finalize liquidation with proof (MockTaskManager accepts any signature).\n        // Collateral=1000, size=10000.',
    text
)
with open('test/integration/UserFlow.t.sol', 'w') as f:
    f.write(text)

print("done")
