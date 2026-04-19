import re
with open('test/unit/PositionManager.t.sol', 'r') as f:
    text = f.read()

text = re.sub(r'vm\.prank\(trader\);\n\s*vm\.prank\(address\(router\)\);\n\s*pm\.openPosition', r'vm.prank(address(router));\n        pm.openPosition', text)
text = re.sub(r'vm\.prank\(trader\);\n\s*vm\.expectRevert\("exceeds max leverage"\);\n\s*vm\.prank\(address\(router\)\);\n\s*pm\.openPosition', r'vm.prank(address(router));\n        vm.expectRevert("exceeds max leverage");\n        pm.openPosition', text)

text = re.sub(r'vm\.prank\(trader\);\n\s*vm\.prank\(address\(router\)\);\n\s*pm\.requestClosePosition', r'vm.prank(address(router));\n        pm.requestClosePosition', text)

with open('test/unit/PositionManager.t.sol', 'w') as f:
    f.write(text)
print("done")
