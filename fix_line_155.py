with open('test/unit/LiquidationManager.t.sol', 'r') as f:
    text = f.read()

import re
text = re.sub(
    r'lm\.liquidate\(trader, token, isLong\);',
    r'bytes32 liqKey1 = pm.getTraderPositionKey(trader, token, isLong);\n        lm.liquidate(liqKey1, token);',
    text
)

with open('test/unit/LiquidationManager.t.sol', 'w') as f:
    f.write(text)
