import re

with open('test/unit/FHEPool.t.sol', 'r') as f:
    text = f.read()

# remove references to frm.
text = re.sub(r'\s*frm\.setPositionManager.*?;\n', '\n', text)
text = re.sub(r'\s*frm\.setRouter.*?;\n', '\n', text)
text = re.sub(r'\s*frm\.setLiquidationManager.*?;\n', '\n', text)
text = re.sub(r'frm\.initializeToken\(address\(oracle\)\);\n', '', text) # FHEFundingRateManager uses it too, check this
text = re.sub(r'address\(frm\)', 'address(fheFRM)', text)

with open('test/unit/FHEPool.t.sol', 'w') as f:
    f.write(text)

