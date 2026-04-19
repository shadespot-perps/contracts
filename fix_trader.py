with open('src/core/LiquidationManager.sol', 'r') as f:
    text = f.read()

import re
text = re.sub(
    r'\s*require\(msg\.sender != trader, "self-liquidation not allowed"\);',
    '',
    text
)

with open('src/core/LiquidationManager.sol', 'w') as f:
    f.write(text)
