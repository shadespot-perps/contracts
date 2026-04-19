with open('test/unit/FHEPool.t.sol', 'r') as f:
    content = f.read()

# Fix test_FHERouter_OpenPosition_Long_PositionExists
content = content.replace(
    """        bytes32 key = pm.getTraderPositionKey(trader, ethToken, true);
        vm.prank(trader);
        PositionManager.Position memory pos = pm.getMyPosition(key);""",
    """        vm.prank(trader);
        PositionManager.Position memory pos = pm.getMyPosition(lastPosId);"""
)

# Fix test_FHERouter_ClosePosition_PositionDeleted — still uses getTraderPositionKey after close
content = content.replace(
    """        bytes32 key = pm.getTraderPositionKey(trader, ethToken, true);
        assertFalse(pm.positionExists(key));""",
    """        assertFalse(pm.positionExists(lastPosId));"""
)

# Fix test_FHERouter_Liquidation_PositionDeleted
content = content.replace(
    """        bytes32 key = pm.getTraderPositionKey(trader, ethToken, true);
        assertFalse(pm.positionExists(key));""",
    """        assertFalse(pm.positionExists(lastPosId));"""
)

# Fix closePosition call - it's passing getPosId(address(this)) which is wrong
# The positionId computed as getPosId(address(this)) = keccak256(address(this), ethToken, 0)
# but the real posId = keccak256(trader, ethToken, 0) [because trader=address(0x20)]
# So all close calls should use lastPosId instead of getPosId(address(this))
content = content.replace(
    'router.closePosition(getPosId(address(this)));',
    'router.closePosition(lastPosId);'
)
content = content.replace(
    'router.closePosition{value: fee}(getPosId(address(this)));',
    'router.closePosition{value: fee}(lastPosId);'
)

with open('test/unit/FHEPool.t.sol', 'w') as f:
    f.write(content)
print("Done")
