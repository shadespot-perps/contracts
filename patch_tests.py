import re

# Fix FHEPool.t.sol: pm.setFheRouter
with open('test/unit/FHEPool.t.sol', 'r') as f:
    fhe_pool = f.read()
if 'pm.setFheRouter' not in fhe_pool:
    fhe_pool = fhe_pool.replace('pm.setRouter(address(router));', 'pm.setRouter(address(router));\n        pm.setFheRouter(address(router));')
with open('test/unit/FHEPool.t.sol', 'w') as f:
    f.write(fhe_pool)

# Fix PositionManager.t.sol: setPendingReservation before openPosition if called directly, oh wait PM openPosition calls vault.reserveLiquidity. But openPosition doesn't set it, Router sets it.
# PM tests call pm.openPosition, but PM openPosition expects vault to already have pending reservation from Router.
# So in PositionManager.t.sol, tests must mock router calling vault.setPendingReservation
with open('test/unit/PositionManager.t.sol', 'r') as f:
    pm_test = f.read()

# Replace direct pm.openPosition calls to pre-call vault.setPendingReservation
# We need to find all vm.prank and pm.openPosition, but since it's tests we can just inject vault.setPendingReservation if we match the pattern.
pm_test = pm_test.replace(
    'pm.openPosition(',
    'vm.prank(router);\n        vault.setPendingReservation(trader, 500e18 * 5);\n        vm.prank(trader);\n        pm.openPosition('
)
# Note: collateral is 500e18, leverage is 5.

with open('test/unit/PositionManager.t.sol', 'w') as f:
    f.write(pm_test)

# Fix LiquidationManager.t.sol
with open('test/unit/LiquidationManager.t.sol', 'r') as f:
    lm_test = f.read()

lm_test = lm_test.replace(
    'pm.openPosition(',
    'vm.prank(address(router));\n        vault.setPendingReservation(trader, 1_000e18 * 10);\n        vm.prank(trader);\n        pm.openPosition('
)
# collateral=1000e18, lev=10

with open('test/unit/LiquidationManager.t.sol', 'w') as f:
    f.write(lm_test)
