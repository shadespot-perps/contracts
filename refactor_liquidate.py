with open('src/core/LiquidationManager.sol', 'r') as f:
    lm = f.read()

import re

# Update liquidate signature in LiquidationManager
lm = re.sub(
    r'function liquidate\(\s*address trader,\s*address token,\s*bool isLong\s*\) external payable',
    'function liquidate(bytes32 positionId, address token) external payable',
    lm
)

# Replace the body of LiquidationManager.liquidate
# Old:
#         bytes32 key = positionManager.getTraderPositionKey(trader, token, isLong);
#         pendingLiquidator[key] = msg.sender;
# 
#         positionManager.liquidate(trader, token, isLong, msg.sender);
# 
#         emit LiquidationExecuted(trader, msg.sender, token);
# New:
#         pendingLiquidator[positionId] = msg.sender;
#         positionManager.liquidate(positionId, msg.sender);
#         emit LiquidationExecuted(msg.sender, token, positionId);

lm = re.sub(
    r'bytes32 key = positionManager\.getTraderPositionKey\(trader, token, isLong\);\n\s*pendingLiquidator\[key\] = msg\.sender;\n\n\s*positionManager\.liquidate\(trader, token, isLong, msg\.sender\);\n\n\s*emit LiquidationExecuted\(trader, msg\.sender, token\);',
    r'pendingLiquidator[positionId] = msg.sender;\n        positionManager.liquidate(positionId, msg.sender);\n        emit LiquidationExecuted(msg.sender, token);', # We will fix the event signature later if needed, wait, the event is trader, liquidator, token.
    lm
)

# Wait, LiquidationExecuted event has trader! We don't have trader unless we fetch it from PositionManager, or change the event to positionId. Let's change the event in LiquidationManager!
lm = lm.replace(
    'event LiquidationExecuted(\n        address indexed trader,\n        address indexed liquidator,\n        address indexed token\n    );',
    'event LiquidationExecuted(\n        bytes32 indexed positionId,\n        address indexed liquidator,\n        address indexed token\n    );'
)
lm = lm.replace(
    'emit LiquidationExecuted(msg.sender, token);',
    'emit LiquidationExecuted(positionId, msg.sender, token);'
)

with open('src/core/LiquidationManager.sol', 'w') as f:
    f.write(lm)


# Now PositionManager.sol
with open('src/core/PositionManager.sol', 'r') as f:
    pm = f.read()

pm = re.sub(
    r'function liquidate\(\s*address trader,\s*address token,\s*bool isLong,\s*address /\* liquidator \*/\s*\) external onlyLiquidationManager {\n\n\s*// ─────────────────────────────────────────────\n\s*// 1\. BASIC CHECKS \(plaintext only\)\n\s*// ─────────────────────────────────────────────\n\s*bytes32 key = _traderPositionKey\[trader\]\[token\]\[isLong\];\n\s*Position storage position = positions\[key\];',
    r'function liquidate(\n        bytes32 positionId,\n        address /* liquidator */\n    ) external onlyLiquidationManager {\n\n    // ─────────────────────────────────────────────\n    // 1. BASIC CHECKS (plaintext only)\n    // ─────────────────────────────────────────────\n    bytes32 key = positionId;\n    Position storage position = positions[key];\n    address token = position.indexToken;',
    pm
)

with open('src/core/PositionManager.sol', 'w') as f:
    f.write(pm)

print("done")
