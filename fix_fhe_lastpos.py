with open('test/unit/FHEPool.t.sol', 'r') as f:
    text = f.read()

text = text.replace(
    'router.openPosition{value: fee}(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true),  true, "");',
    'lastPosId = router.openPosition{value: fee}(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true),  true, "");'
)

with open('test/unit/FHEPool.t.sol', 'w') as f:
    f.write(text)
