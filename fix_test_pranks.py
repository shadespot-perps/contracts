import re

with open('test/unit/LiquidationManager.t.sol', 'r') as f:
    content = f.read()

# Fix LiquidationManager.t.sol
# Replace:
# vm.prank(liquidator);
# lm.finalizeLiquidation(pm.getTraderPositionKey(trader, token, isLong), ...);
# With:
# bytes32 liqKey = pm.getTraderPositionKey(trader, token, isLong);
# vm.prank(liquidator);
# lm.finalizeLiquidation(liqKey, ...);

content = re.sub(
    r'vm\.prank\(liquidator\);\n\s+lm\.finalizeLiquidation\(pm\.getTraderPositionKey\(trader, token, isLong\), (.*?)\);',
    r'bytes32 liqKey = pm.getTraderPositionKey(trader, token, isLong);\n        vm.prank(liquidator);\n        lm.finalizeLiquidation(liqKey, \1);',
    content
)

with open('test/unit/LiquidationManager.t.sol', 'w') as f:
    f.write(content)


with open('test/unit/PositionManager.t.sol', 'r') as f:
    content = f.read()

# PositionManager.t.sol has:
# vm.prank(trader);
# pm.finalizeClosePosition(pm.getTraderPositionKey(trader, token, isLong), ...);
content = re.sub(
    r'vm\.prank\(trader\);\n\s+pm\.finalizeClosePosition\(pm\.getTraderPositionKey\(trader, token, isLong\), (.*?)\);',
    r'bytes32 posKey = pm.getTraderPositionKey(trader, token, isLong);\n        vm.prank(trader);\n        pm.finalizeClosePosition(posKey, \1);',
    content
)
# Also check for startPrank cases
content = re.sub(
    r'pm\.finalizeClosePosition\(pm\.getTraderPositionKey\(trader, token, isLong\), (.*?)\);',
    r'bytes32 posKey = pm.getTraderPositionKey(trader, token, isLong);\n        pm.finalizeClosePosition(posKey, \1);',
    content
)

with open('test/unit/PositionManager.t.sol', 'w') as f:
    f.write(content)
