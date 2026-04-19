import re

# Fix FHEPool.t.sol prank eating by FHE.asEuint64
with open('test/unit/FHEPool.t.sol', 'r') as f:
    text = f.read()

# Replace block for submitReserveLiquidityCheck in FHEPool.t.sol:
# find:
#         vm.prank(address(router));
#         vault.submitReserveLiquidityCheck(address(pm), FHE.asEuint64(SIZE));
text = re.sub(
    r'(\s*vm\.prank\([^)]+\);\s*)vault\.submitReserveLiquidityCheck\(([^,]+),\s*FHE\.asEuint64\(([^)]+)\)\);',
    r'\n        euint64 __eSize = FHE.asEuint64(\3);\1vault.submitReserveLiquidityCheck(\2, __eSize);',
    text
)
with open('test/unit/FHEPool.t.sol', 'w') as f:
    f.write(text)

# Fix LiquidationManager.t.sol and PositionManager.t.sol prank overwrite
def fix_overwrite(filepath):
    with open(filepath, 'r') as f:
        content = f.read()
    # we added vm.prank(router); ... vm.prank(trader); pm.openPosition(...), which was after a vm.prank(trader);
    # let's look for:
    #         vm.prank(trader);
    #         vm.prank(router);
    #         vault.setPendingReservation(trader, ...);
    #         vm.prank(trader);
    content = re.sub(
        r'vm\.prank\(([^)]+)\);\s*vm\.prank\(address\(router\)\);\s*(vault\.setPendingReservation\([^)]+\);\s*)vm\.prank\([^)]+\);',
        r'vm.prank(address(router));\n        \2vm.prank(\1);',
        content
    )
    content = content.replace('vm.prank(router);', 'vm.prank(address(router));')
    with open(filepath, 'w') as f:
        f.write(content)

fix_overwrite('test/unit/PositionManager.t.sol')
fix_overwrite('test/unit/LiquidationManager.t.sol')

# Fix Vault.t.sol Not router
with open('test/unit/Vault.t.sol', 'r') as f:
    vault_test = f.read()
vault_test = vault_test.replace(
    'vault.setPendingReservation(address(this), 800 * 1e18);',
    'vm.prank(address(router));\n        vault.setPendingReservation(address(this), 800 * 1e18);'
)
vault_test = vault_test.replace(
    'vault.setPendingReservation(address(this), 500 * 1e18);',
    'vm.prank(address(router));\n        vault.setPendingReservation(address(this), 500 * 1e18);'
)
with open('test/unit/Vault.t.sol', 'w') as f:
    f.write(vault_test)
