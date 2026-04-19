import re

with open('test/unit/Vault.t.sol', 'r') as f:
    text = f.read()

# Fix pranks in Vault.t.sol
text = text.replace(
    'vm.prank(positionManager);\n        vm.prank(address(router));\n        vault.setPendingReservation(address(this), 800 * 1e18);\n        vault.reserveLiquidity(address(this));',
    'vm.prank(address(router));\n        vault.setPendingReservation(address(this), 800 * 1e18);\n        vm.prank(positionManager);\n        vault.reserveLiquidity(address(this));'
)

text = text.replace(
    'vm.prank(positionManager);\n        vm.prank(address(router));\n        vault.setPendingReservation(address(this), 500 * 1e18);\n        vault.reserveLiquidity(address(this));',
    'vm.prank(address(router));\n        vault.setPendingReservation(address(this), 500 * 1e18);\n        vm.prank(positionManager);\n        vault.reserveLiquidity(address(this));'
)

text = text.replace(
    'vm.prank(positionManager);\n        vm.expectRevert("Insufficient vault liquidity");\n        vm.prank(address(router));\n        vault.setPendingReservation(address(this), 500 * 1e18);\n        vault.reserveLiquidity(address(this));',
    'vm.prank(address(router));\n        vault.setPendingReservation(address(this), 500 * 1e18);\n        vm.prank(positionManager);\n        vm.expectRevert("Insufficient vault liquidity");\n        vault.reserveLiquidity(address(this));'
)

with open('test/unit/Vault.t.sol', 'w') as f:
    f.write(text)

with open('test/unit/PositionManager.t.sol', 'r') as f:
    pm = f.read()
# Revert the double pranks in PositionManager.t.sol!
pm = pm.replace(
    'vm.prank(address(router));\n        vm.prank(trader);\n        vault.setPendingReservation(trader, 500e18 * 5);',
    'vm.prank(address(router));\n        vault.setPendingReservation(trader, 500e18 * 5);\n        vm.prank(trader);'
)
with open('test/unit/PositionManager.t.sol', 'w') as f:
    f.write(pm)

with open('test/unit/LiquidationManager.t.sol', 'r') as f:
    lm = f.read()
lm = lm.replace(
    'vm.prank(address(router));\n        vm.prank(trader);\n        vault.setPendingReservation(trader, 1_000e18 * 10);',
    'vm.prank(address(router));\n        vault.setPendingReservation(trader, 1_000e18 * 10);\n        vm.prank(trader);'
)
with open('test/unit/LiquidationManager.t.sol', 'w') as f:
    f.write(lm)
