with open('test/unit/LiquidationManager.t.sol', 'r') as f:
    text = f.read()

text = text.replace(
    'lm.finalizeLiquidation(pm.getTraderPositionKey(trader, token, isLong), false, "", collateral, "", collateral * leverage, "", isLong);',
    'lm.finalizeLiquidation(liqKey1, false, "", collateral, "", collateral * leverage, "", isLong);'
)

with open('test/unit/LiquidationManager.t.sol', 'w') as f:
    f.write(text)
