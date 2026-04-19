import re

for filepath in ['test/unit/FHEPool.t.sol', 'test/unit/PositionManager.t.sol', 'test/unit/Vault.t.sol', 'test/unit/OrderManager.t.sol', 'test/integration/UserFlow.t.sol', 'test/unit/LiquidationManager.t.sol']:
    with open(filepath, 'r') as f:
        content = f.read()

    # Add import
    import_str = 'import "../../src/core/FHEFundingRateManager.sol";\n'
    if import_str not in content:
        content = content.replace('import "../../src/core/FundingRateManager.sol";', 'import "../../src/core/FundingRateManager.sol";\n' + import_str)
    
    # Add variable
    var_str = '    FHEFundingRateManager public fundingManagerFHE;\n'
    if var_str not in content:
        content = content.replace('    FundingRateManager public fundingManager;', '    FundingRateManager public fundingManager;\n' + var_str)
        
    # Add deployment to setUp()
    setup_target = '        fundingManager = new FundingRateManager();'
    setup_repl = '        fundingManager = new FundingRateManager();\n        fundingManagerFHE = new FHEFundingRateManager();'
    if 'fundingManagerFHE = new FHEFundingRateManager();' not in content:
        content = content.replace(setup_target, setup_repl)
        
    # Add setting PM to FHEFundingRateManager
    pm_set_target = '        positionManager.setFundingManager(address(fundingManager));'
    pm_set_repl = '        positionManager.setFundingManager(address(fundingManager));\n        positionManager.setFHEFundingManager(address(fundingManagerFHE));\n        fundingManagerFHE.setPositionManager(address(positionManager));'
    if 'positionManager.setFHEFundingManager' not in content:
        content = content.replace(pm_set_target, pm_set_repl)

    with open(filepath, 'w') as f:
        f.write(content)

