import os, glob, re

def remove_import(path, import_str):
    if not os.path.exists(path): return
    with open(path, 'r') as f:
        content = f.read()
    content = re.sub(import_str, '', content, flags=re.MULTILINE)
    with open(path, 'w') as f:
        f.write(content)

# Fix LiquidationManager.t.sol
remove_import('test/unit/LiquidationManager.t.sol', r'import "\.\./\.\./src/core/Vault\.sol";\n')
remove_import('test/unit/LiquidationManager.t.sol', r'import "\.\./\.\./src/core/FundingRateManager\.sol";\n')

# Fix PositionManager.t.sol
remove_import('test/unit/PositionManager.t.sol', r'import "\.\./\.\./src/core/Vault\.sol";\n')
remove_import('test/unit/PositionManager.t.sol', r'import "\.\./\.\./src/core/FundingRateManager\.sol";\n')

# Fix deployments
remove_import('script/Deploy.s.sol', r'import "\.\./src/core/FundingRateManager\.sol";\n')
remove_import('script/Deploy.s.sol', r'import "\.\./src/core/Vault\.sol";\n')
remove_import('script/Deploy.s.sol', r'import "\.\./src/trading/OrderManager\.sol";\n')
remove_import('script/Deploy.s.sol', r'import "\.\./src/trading/Router\.sol";\n')

remove_import('script/DeployPool2Only.s.sol', r'import "\.\./src/core/FundingRateManager\.sol";\n')
remove_import('script/DeployPool2Only.s.sol', r'import "\.\./src/trading/OrderManager\.sol";\n')

