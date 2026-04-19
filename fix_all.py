import os, glob, re

def replace_in_file(path, old, new):
    if not os.path.exists(path): return
    with open(path, 'r') as f:
        content = f.read()
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)

def remove_import(path, import_str):
    if not os.path.exists(path): return
    with open(path, 'r') as f:
        content = f.read()
    content = re.sub(import_str, '', content, flags=re.MULTILINE)
    with open(path, 'w') as f:
        f.write(content)

# src/core/LiquidationManager.sol
remove_import('src/core/LiquidationManager.sol', r'import "\.\./core/FundingRateManager\.sol";\n')

# src/trading/FHEOrderManager.sol
remove_import('src/trading/FHEOrderManager.sol', r'import "\.\./core/FundingRateManager\.sol";\n')
replace_in_file('src/trading/FHEOrderManager.sol', 'FundingRateManager public fundingManager;', '')
replace_in_file('src/trading/FHEOrderManager.sol', '        fundingManager = FundingRateManager(_fundingManager);', '')
replace_in_file('src/trading/FHEOrderManager.sol', '        // Update funding before operations\n        fundingManager.updateFunding(token);\n', '')

# src/trading/FHERouter.sol
remove_import('src/trading/FHERouter.sol', r'import "\.\./core/FundingRateManager\.sol";\n')
replace_in_file('src/trading/FHERouter.sol', 'FundingRateManager public fundingManager;', '')
replace_in_file('src/trading/FHERouter.sol', '        fundingManager = FundingRateManager(_fundingManager);\n', '')
replace_in_file('src/trading/FHERouter.sol', '        fundingManager.updateFunding(token);\n', '')

# Deployments
replace_in_file('script/DeployDualPool.s.sol', 'import "../src/trading/Router.sol";\n', '')
replace_in_file('script/DeployDualPool.s.sol', 'import "../src/trading/OrderManager.sol";\n', '')
replace_in_file('script/DeployDualPool.s.sol', 'import "../src/core/Vault.sol";\n', '')
replace_in_file('script/DeployDualPool.s.sol', 'import "../src/core/FundingRateManager.sol";\n', '')

# FHEPool.t.sol
remove_import('test/unit/FHEPool.t.sol', r'import "\.\./\.\./src/core/FundingRateManager\.sol";\n')
remove_import('test/unit/FHEPool.t.sol', r'import "\.\./\.\./src/trading/OrderManager\.sol";\n')

