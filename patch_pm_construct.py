import re

with open('src/core/PositionManager.sol', 'r') as f:
    text = f.read()

# remove state variable
text = re.sub(r'    FundingRateManager public fundingManager;\n', '', text)

# remove constructor parameter
text = re.sub(r', address _fundingManager', '', text)

# remove assignment in constructor
text = re.sub(r'        fundingManager = FundingRateManager\(_fundingManager\);\n', '', text)

# also since we are pure FHE we don't need setFundingManager
text = re.sub(r'    function setFundingManager.*?\}\n', '', text, flags=re.DOTALL)

with open('src/core/PositionManager.sol', 'w') as f:
    f.write(text)

