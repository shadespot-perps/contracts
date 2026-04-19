import re

with open('test/unit/FHEPool.t.sol', 'r') as f:
    content = f.read()

# Fix mockInEbool
wrong_mock = "return InEbool({data: bytes32(uint256(value ? 1 : 0))});"
right_mock = "return InEbool({ctHash: uint256(value ? 1 : 0), securityZone: 0, utype: 0, signature: bytes('')});"
content = content.replace(wrong_mock, right_mock)

# Replace the remaining uses of lev and isLong in the openPosition / submit tasks
content = re.sub(
    r'router\.submitDecryptTaskForOpen\(([^,]+), mockInEuint64\(([^)]+)\), ([^)]+)\);',
    r'router.submitDecryptTaskForOpen(\1, mockInEuint64(\2), mockInEuint64(uint64(\3)), mockInEbool(true));',
    content
)

content = re.sub(
    r'router\.openPosition\(([^,]+), mockInEuint64\(([^)]+)\), ([^,]+), ([^,]+),  true, ""\);',
    r'router.openPosition(\1, mockInEuint64(\2), mockInEuint64(uint64(\3)), mockInEbool(\4), true, "");',
    content
)

content = re.sub(
    r'router\.openPosition(\{value:\s*fee\}\)\(([^,]+), mockInEuint64\(([^)]+)\), ([^,]+), ([^,]+),  true, ""\);',
    r'router.openPosition{value: fee}(\1, mockInEuint64(\2), mockInEuint64(uint64(\3)), mockInEbool(\4), true, "");',
    content
)

with open('test/unit/FHEPool.t.sol', 'w') as f:
    f.write(content)

