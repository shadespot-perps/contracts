import re

with open('src/core/PositionManager.sol', 'r') as f:
    text = f.read()

# Remove imports
text = re.sub(r'import "\./FundingRateManager\.sol";\n', '', text)
text = re.sub(r'import "\./Vault\.sol";\n', '', text)
# In constructor args
text = re.sub(r'address _fm,', '', text)
# In constructor body
text = re.sub(r'fundingManager = FundingRateManager\(_fm\);\n', '', text)

# Remove plaintext state vars
text = re.sub(r'\s*FundingRateManager public fundingManager;\n', '\n', text)
text = re.sub(r'    function setFundingManager\(address _fm\) external onlyOwner \{\n        fundingManager = FundingRateManager\(_fm\);\n    \}\n', '', text)

# We need to drop "onlyRouter" modifier
text = re.sub(r'\s*modifier onlyRouter\(\) \{\n.*?\}', '', text, flags=re.DOTALL)

# Delete openPosition
text = re.sub(r'\s*function openPosition\(.*?\) external onlyRouter \{.*?\n    \}', '', text, flags=re.DOTALL)

# Delete requestClosePosition
text = re.sub(r'\s*function requestClosePosition\(\n.*?\) external onlyRouter \{.*?\n    \}', '', text, flags=re.DOTALL)

with open('src/core/PositionManager.sol', 'w') as f:
    f.write(text)

