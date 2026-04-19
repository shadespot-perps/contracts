with open('test/unit/PositionManager.t.sol', 'r') as f:
    content = f.read()

content = content.replace(
    '        vm.prank(address(router));\n        vm.prank(address(router));',
    '        vm.prank(address(router));'
)

content = content.replace(
    '        vm.prank(address(router));\n        vm.expectRevert("exceeds max leverage");\n        vm.prank(address(router));',
    '        vm.prank(address(router));\n        vault.setPendingReservation(trader, 500e18 * 5);\n        vm.expectRevert("exceeds max leverage");\n        vm.prank(trader);'
)

# wait there was a line 'vault.setPendingReservation(trader, 500e18 * 5);'
# In test_OpenPosition_Revert_MaxLeverage:
# 99:         vm.prank(address(router));
# 100:         vm.expectRevert("exceeds max leverage");
# 101:         vm.prank(address(router));
# 102:         vault.setPendingReservation(trader, 500e18 * 5);
# 103:         vm.prank(trader);
# 104:         pm.openPosition(trader, token, 1000, 11, true);

import re
content = re.sub(
    r'vm\.prank\(address\(router\)\);\n\s+vm\.expectRevert\("exceeds max leverage"\);\n\s+vm\.prank\(address\(router\)\);\n\s+vault\.setPendingReservation\(trader, 500e18 \* 5\);\n\s+vm\.prank\(trader\);\n\s+pm\.openPosition\(trader, token, 1000, 11, true\);',
    r'vm.prank(address(router));\n        vault.setPendingReservation(trader, 500e18 * 5);\n        vm.prank(trader);\n        vm.expectRevert("exceeds max leverage");\n        pm.openPosition(trader, token, 1000, 11, true);',
    content
)

with open('test/unit/PositionManager.t.sol', 'w') as f:
    f.write(content)

print("done")
