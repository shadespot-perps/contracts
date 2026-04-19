with open('test/unit/PositionManager.t.sol', 'r') as f:
    text = f.read()

text = text.replace(
    '        pm.openPosition',
    '        vm.prank(address(router));\n        pm.openPosition'
)

text = text.replace(
    '        pm.requestClosePosition',
    '        vm.prank(address(router));\n        pm.requestClosePosition'
)
# Make sure we don't double prank
import re
text = re.sub(r'vm\.prank\(address\(router\)\);\n\s*vm\.prank\(address\(router\)\);', r'vm.prank(address(router));', text)

with open('test/unit/PositionManager.t.sol', 'w') as f:
    f.write(text)

print("done")
