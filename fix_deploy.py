import re

with open('script/DeployDualPool.s.sol', 'r') as f:
    text = f.read()

# Update OrderManager instantiation
text = re.sub(
    r'orderManager2 = new FHEOrderManager\(\n\s*address\(oracle2\),\n\s*deployer\n\s*\);',
    r'orderManager2 = new FHEOrderManager(\n            address(oracle2),\n            address(fheFundingManager2),\n            deployer\n        );',
    text
)
# Note: I completely deleted the plaintext order manager logic earlier, so let's just make sure.
text = re.sub(
    r'orderManager2 = new FHEOrderManager\(\n\s*address\(oracle2\),\n\s*address\(fundingManager2\),\n\s*deployer\n\s*\);',
    r'orderManager2 = new FHEOrderManager(\n            address(oracle2),\n            address(fheFundingManager2),\n            deployer\n        );',
    text
)

# Update FHERouter instantiation
text = re.sub(
    r'router2 = new FHERouter\(\n\s*address\(positionManager2\),\n\s*address\(vault2\),\n\s*address\(orderManager2\),\n\s*collateralToken,\n\s*indexToken_\n\s*\);',
    r'router2 = new FHERouter(\n            address(positionManager2),\n            address(vault2),\n            address(orderManager2),\n            address(fheFundingManager2),\n            collateralToken,\n            indexToken_\n        );',
    text
)
text = re.sub(
    r'router2 = new FHERouter\(\n\s*address\(positionManager2\),\n\s*address\(vault2\),\n\s*address\(orderManager2\),\n\s*address\(fundingManager2\),\n\s*collateralToken,\n\s*indexToken_\n\s*\);',
    r'router2 = new FHERouter(\n            address(positionManager2),\n            address(vault2),\n            address(orderManager2),\n            address(fheFundingManager2),\n            collateralToken,\n            indexToken_\n        );',
    text
)

with open('script/DeployDualPool.s.sol', 'w') as f:
    f.write(text)

