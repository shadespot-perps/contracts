import re

with open('test/unit/FHEPool.t.sol', 'r') as f:
    text = f.read()

# Replace variables
text = re.sub(r'\s*FundingRateManager frm;\n', '\n', text)
text = re.sub(r'\s*OrderManager\s+om;\n', '    FHEOrderManager    om;\n', text)

# Replace instantiations
text = re.sub(r'\s*frm\s*=\s*new FundingRateManager\(\);\n', '\n', text)
text = re.sub(r'address\(frm\)', 'address(fheFRM)', text)

text = re.sub(r'om\s*=\s*new OrderManager\(address\(oracle\), address\(fheFRM\), owner\);\n', 'om     = new FHEOrderManager(address(oracle), address(fheFRM), owner);\n', text)
# If the original was: om = new OrderManager(address(oracle), address(frm), owner);
text = re.sub(r'om\s*=\s*new OrderManager\(.*?\);\n', 'om     = new FHEOrderManager(address(oracle), address(fheFRM), owner);\n', text)

# Add missing import for FHEOrderManager
text = re.sub(r'import "\.\./\.\./src/trading/FHERouter\.sol";\n', 'import "../../src/trading/FHERouter.sol";\nimport "../../src/trading/FHEOrderManager.sol";\n', text)

# PositionManager constructor changed (removed fm)
text = re.sub(r'new PositionManager\(address\(vault\), address\(oracle\), address\(fheFRM\)\)', 'new PositionManager(address(vault), address(oracle))', text)

with open('test/unit/FHEPool.t.sol', 'w') as f:
    f.write(text)

