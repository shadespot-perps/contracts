import re

with open('test/integration/UserFlow.t.sol', 'r') as f:
    text = f.read()

text = re.sub(
    r'vm\.prank\(liquidator\);\n\s*bytes32 (liqKey.*?) = positionManager\.getTraderPositionKey',
    r'bytes32 \1 = positionManager.getTraderPositionKey',
    text
)
# insert it before liquidationManager.liquidate
text = re.sub(
    r'(bytes32 liqKey.*?;\n\s*)liquidationManager\.liquidate',
    r'\1vm.prank(liquidator);\n        liquidationManager.liquidate',
    text
)

with open('test/integration/UserFlow.t.sol', 'w') as f:
    f.write(text)

with open('test/unit/LiquidationManager.t.sol', 'r') as f:
    text = f.read()

text = re.sub(
    r'vm\.prank\(liquidator\);\n\s*bytes32 (liqKey.*?) = pm\.getTraderPositionKey',
    r'bytes32 \1 = pm.getTraderPositionKey',
    text
)
text = re.sub(
    r'(bytes32 liqKey.*?;\n\s*)lm\.liquidate',
    r'\1vm.prank(liquidator);\n        lm.liquidate',
    text
)

# And similarly for the expectRevert case!
#         bytes32 liqKey0 = pm.getTraderPositionKey(trader, token, isLong);
#         vm.expectRevert("Insufficient ETH fee");
#         lm.liquidate(liqKey0, token);
# We must insert vm.prank(liquidator); BEFORE vm.expectRevert!
text = re.sub(
    r'(bytes32 liqKey0.*?;\n\s*)vm\.expectRevert',
    r'\1vm.prank(liquidator);\n        vm.expectRevert',
    text
)

with open('test/unit/LiquidationManager.t.sol', 'w') as f:
    f.write(text)

print("done")
