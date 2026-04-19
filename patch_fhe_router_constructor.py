import re

with open('src/trading/FHERouter.sol', 'r') as f:
    text = f.read()

text = re.sub(r'address _fundingManager,', 'address _fheFunding,', text)
text = re.sub(r'orderManager = FHEOrderManager\(_orderManager\);\n', 'orderManager = FHEOrderManager(_orderManager);\n        fheFundingManager = FHEFundingRateManager(_fheFunding);\n', text)

with open('src/trading/FHERouter.sol', 'w') as f:
    f.write(text)

