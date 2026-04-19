import re

with open('test/unit/FHEPool.t.sol', 'r') as f:
    content = f.read()

content = content.replace(
    'import { FHE, euint64 }',
    'import { FHE, euint64, InEuint64, InEuint128 }'
)

mock_func = """
    function mockInEuint64(uint256 val) internal pure returns (InEuint64 memory) {
        return InEuint64({
            ctHash: val,
            securityZone: 0,
            utype: 5,
            signature: ""
        });
    }

    function mockInEuint128(uint256 val) internal pure returns (InEuint128 memory) {
        return InEuint128({
            ctHash: val,
            securityZone: 0,
            utype: 6,
            signature: ""
        });
    }
    // ── helper:"""

content = content.replace('    // ── helper:', mock_func)

content = content.replace('router.addLiquidity(LP_SEED)', 'router.addLiquidity(mockInEuint64(LP_SEED))')
content = content.replace('router.addLiquidity(extra)', 'router.addLiquidity(mockInEuint64(extra))')

content = re.sub(r'router.submitDecryptTaskForOpen\(([^,]+),\s*([^,]+),\s*([^)]+)\)',
                 r'router.submitDecryptTaskForOpen(\1, mockInEuint64(\2), \3)', content)

content = re.sub(r'router.openPosition\(([^,]+),\s*([^,]+),\s*([^,]+),\s*([^,]+),([^,]+),\s*([^)]+)\)',
                 r'router.openPosition(\1, mockInEuint64(\2), \3, \4, \5, \6)', content)

content = re.sub(r'router.openPosition\{value:\s*fee\}\(([^,]+),\s*([^,]+),\s*([^,]+),\s*([^,]+),([^,]+),\s*([^)]+)\)',
                 r'router.openPosition{value: fee}(\1, mockInEuint64(\2), \3, \4, \5, \6)', content)

content = re.sub(r'vault.submitReserveLiquidityCheck\(([^,]+),\s*([^)]+)\)',
                 r'vault.submitReserveLiquidityCheck(\1, FHE.asEuint64(\2))', content)

content = re.sub(r'vault.reserveLiquidity\([^,]+,\s*([^)]+)\)',
                 r'vault.reserveLiquidity(\1)', content)

with open('test/unit/FHEPool.t.sol', 'w') as f:
    f.write(content)
