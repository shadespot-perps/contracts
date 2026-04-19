# Fix LiquidationManager.t.sol
with open('test/unit/LiquidationManager.t.sol', 'r') as f:
    content = f.read()

# Add FHEFundingRateManager to pm setup if not there
if 'fheFRM' not in content:
    content = content.replace(
        '    FundingRateManager frm;\n    ERC20Mock collateralToken;',
        '    FundingRateManager frm;\n    FHEFundingRateManager fheFRM;\n    ERC20Mock collateralToken;'
    )
    content = content.replace(
        '        frm    = new FundingRateManager();\n        vault  = new Vault(token, owner);\n\n        pm = new PositionManager(address(vault), address(oracle), address(frm));',
        '        frm    = new FundingRateManager();\n        fheFRM = new FHEFundingRateManager();\n        vault  = new Vault(token, owner);\n\n        pm = new PositionManager(address(vault), address(oracle), address(frm));'
    )
    content = content.replace(
        '        pm.setRouter(router);\n        pm.setLiquidationManager(address(lm));\n        pm.setFinalizer(address(this)); // test contract acts as trusted finalizer for close\n        vault.setPositionManager(address(pm));\n        vault.setRouter(router);\n        frm.setPositionManager(address(pm));\n        frm.setRouter(router);',
        '        pm.setRouter(router);\n        pm.setLiquidationManager(address(lm));\n        pm.setFinalizer(address(this)); // test contract acts as trusted finalizer for close\n        pm.setFundingManager(address(frm));\n        pm.setFHEFundingManager(address(fheFRM));\n        fheFRM.setPositionManager(address(pm));\n        vault.setPositionManager(address(pm));\n        vault.setRouter(router);\n        frm.setPositionManager(address(pm));\n        frm.setRouter(router);'
    )

# Fix finalizeLiquidation calls in LM tests
# Old: lm.finalizeLiquidation(trader, token, isLong, canLiq, "", coll, "", size, "")
# New: lm.finalizeLiquidation(key, canLiq, "", coll, "", size, "", isLong)
import re
content = re.sub(
    r'lm\.finalizeLiquidation\(trader, token, isLong, (true|false), "", collateral, "", collateral \* leverage, ""\);',
    r'lm.finalizeLiquidation(pm.getTraderPositionKey(trader, token, isLong), \1, "", collateral, "", collateral * leverage, "", isLong);',
    content
)

with open('test/unit/LiquidationManager.t.sol', 'w') as f:
    f.write(content)

# Fix PositionManager.t.sol
with open('test/unit/PositionManager.t.sol', 'r') as f:
    content = f.read()

# Fix finalizeClosePosition call
content = content.replace(
    'pm.finalizeClosePosition(trader, token, isLong, 1500 * 1e18, "", collateral * leverage, "", false, "");',
    'pm.finalizeClosePosition(pm.getTraderPositionKey(trader, token, isLong), 1500 * 1e18, "", collateral * leverage, "", isLong);'
)

with open('test/unit/PositionManager.t.sol', 'w') as f:
    f.write(content)

# Fix FHEPool.t.sol finalizeClosePosition calls
with open('test/unit/FHEPool.t.sol', 'r') as f:
    content = f.read()

# Old: pm.finalizeClosePosition(trader, ethToken, true, amount, "", size, "", false, "")
# New: pm.finalizeClosePosition(positionKey, amount, "", size, "", true)
content = re.sub(
    r'pm\.finalizeClosePosition\(trader, ethToken, (true|false), (uint256\([^)]+\)), "", (uint256\([^)]+\)), "", false, ""\);',
    r'pm.finalizeClosePosition(lastPosId, \2, "", \3, "", \1);',
    content
)

# Need to capture lastPosId in FHE tests - it's returned from openPositionFHE -> openPosition
# For close tests the open already returns posId - we need to look at how openPosition is called
# Let's check if openPosition returns posId

with open('test/unit/FHEPool.t.sol', 'w') as f:
    f.write(content)

print("Done")
