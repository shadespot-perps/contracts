import re

with open('test/unit/FHEPool.t.sol', 'r') as f:
    content = f.read()

mock_ebool = """
    function mockInEbool(bool value) public pure returns (InEbool memory) {
        return InEbool({data: bytes32(uint256(value ? 1 : 0))});
    }

"""
if 'function mockInEbool' not in content:
    content = content.replace('    function mockInEuint64', mock_ebool + '    function mockInEuint64')

# Replace submitDecryptTaskForOpen
content = content.replace(
    'router.submitDecryptTaskForOpen(wrongToken, mockInEuint64(COLLATERAL), LEVERAGE);',
    'router.submitDecryptTaskForOpen(wrongToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true));'
)
content = content.replace(
    'router.submitDecryptTaskForOpen(ethToken, mockInEuint64(COLLATERAL), LEVERAGE);',
    'router.submitDecryptTaskForOpen(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true));'
)

# Replace openPosition
content = content.replace(
    'router.openPosition(ethToken, mockInEuint64(COLLATERAL), LEVERAGE, true,  true, "");',
    'router.openPosition(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true),  true, "");'
)
content = content.replace(
    'router.openPosition{value: fee}(ethToken, mockInEuint64(COLLATERAL), LEVERAGE, true,  true, "");',
    'router.openPosition{value: fee}(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEbool(true),  true, "");'
)

# Replace createOrder
content = content.replace(
    'router.createOrder(ethToken, mockInEuint64(COLLATERAL), LEVERAGE, mockInEuint128(TRIGGER_PRICE), true);',
    'router.createOrder(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEuint128(TRIGGER_PRICE), mockInEbool(true));'
)
content = content.replace(
    'router.createOrder{value: fee}(ethToken, mockInEuint64(COLLATERAL), LEVERAGE, mockInEuint128(TRIGGER_PRICE), true);',
    'router.createOrder{value: fee}(ethToken, mockInEuint64(COLLATERAL), mockInEuint64(uint64(LEVERAGE)), mockInEuint128(TRIGGER_PRICE), mockInEbool(true));'
)


# Replace closePosition
# we know the user is `address(this)` when tests call it, except in prank.
# Let's just create a helper `getPosId` at the top of the test
helper = """    function getPosId(address user) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(user, address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2), uint256(0)));
    }
"""
if 'function getPosId(' not in content:
    content = content.replace('    uint256 public constant TRIGGER_PRICE = 2000e18;', '    uint256 public constant TRIGGER_PRICE = 2000e18;\n' + helper)

content = content.replace(
    'router.closePosition(ethToken, true);',
    'router.closePosition(getPosId(address(this)));'
)
content = content.replace(
    'router.closePosition{value: fee}(ethToken, true);',
    'router.closePosition{value: fee}(getPosId(address(this)));'
)

with open('test/unit/FHEPool.t.sol', 'w') as f:
    f.write(content)
