import re

def add_fhe_funding(path):
    with open(path, 'r') as f:
        text = f.read()

    # Add import
    text = re.sub(r'import "\./FHERouter\.sol";\n', 'import "./FHERouter.sol";\nimport "../core/FHEFundingRateManager.sol";\n', text)
    if 'FHEFundingRateManager' not in text:
        text = re.sub(r'import "\.\./core/IVault\.sol";\n', 'import "../core/IVault.sol";\nimport "../core/FHEFundingRateManager.sol";\n', text)

    # Add var
    text = re.sub(r'    address public owner;\n', '    address public owner;\n    FHEFundingRateManager public fheFundingManager;\n', text)

    # Add to constructor
    text = re.sub(r'address _oracle,\n\s*address _deployer\n', r'address _oracle,\n        address _fheFunding,\n        address _deployer\n', text)
    text = re.sub(r'owner = _deployer;', r'owner = _deployer;\n        fheFundingManager = FHEFundingRateManager(_fheFunding);', text)

    # Note: FHERouter constructor is different
    text = re.sub(r'address _orderManager,\n\s*address _collateralToken,\n', r'address _orderManager,\n        address _fheFunding,\n        address _collateralToken,\n', text)
    text = re.sub(r'orderManager = FHEOrderManager\(_orderManager\);\n', r'orderManager = FHEOrderManager(_orderManager);\n        fheFundingManager = FHEFundingRateManager(_fheFunding);\n', text)

    # Remove the orphaned one in FHEOrderManager line 251
    text = re.sub(r'\s*fundingManager\.updateFunding\(order\.token\);\n', '\n        fheFundingManager.updateFunding(order.token);\n', text)

    with open(path, 'w') as f:
        f.write(text)

add_fhe_funding('src/trading/FHEOrderManager.sol')
add_fhe_funding('src/trading/FHERouter.sol')

# We need to manually add the updateFunding calls to openPosition in router
with open('src/trading/FHERouter.sol', 'r') as f:
    text = f.read()
text = text.replace('require(token == indexToken, "unsupported index token");\n', 'require(token == indexToken, "unsupported index token");\n\n        fheFundingManager.updateFunding(token);\n')
with open('src/trading/FHERouter.sol', 'w') as f:
    f.write(text)

