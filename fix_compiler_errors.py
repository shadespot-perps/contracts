import re

with open('src/core/PositionManager.sol', 'r') as f:
    content = f.read()

# Fix eLeverage128 redeclaration
content = content.replace('        euint128 eLeverage128 = FHE.asEuint128(eLeverage);\n', '')

# Fix natspec errors in PositionManager by safely replacing them
content = content.replace('* @param leverage      Leverage multiplier (plaintext).', '* @param eLeverage   Encrypted leverage.')
content = content.replace('* @param isLong        True if long, false if short.', '* @param eIsLong     Encrypted long/short direction.')

# Let's fix missing isLongPlain in finalizeLiquidation wrapper ? Wait!
# The problem is `finalizeLiquidation` signature: I already replaced it with isLongPlain!
# But wait, let's see why it's undeclared:
# In `finalizeLiquidation` I replaced it!

# Let's write the modified content back
with open('src/core/PositionManager.sol', 'w') as f:
    f.write(content)
