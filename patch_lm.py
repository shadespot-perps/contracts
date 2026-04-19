import re

with open('src/core/LiquidationManager.sol', 'r') as f:
    text = f.read()

# Add import for FHEFundingRateManager
text = re.sub(r'import "\./PositionManager\.sol";\n', 'import "./PositionManager.sol";\nimport "./FHEFundingRateManager.sol";\n', text)

# Replace state variable
text = re.sub(r'FundingRateManager public fundingManager;', 'FHEFundingRateManager public fundingManager;', text)

# Replace constructor args and assignment
text = re.sub(r'address _fundingManager', 'address _fundingManager', text)
text = re.sub(r'fundingManager = FundingRateManager', 'fundingManager = FHEFundingRateManager', text)

with open('src/core/LiquidationManager.sol', 'w') as f:
    f.write(text)

