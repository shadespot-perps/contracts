import re

with open('test/unit/FHEPool.t.sol', 'r') as f:
    content = f.read()

helper = """
    function getPosId(address user) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(user, address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2), uint256(0)));
    }
"""

if 'contract FHEPoolTest is Test {' in content and 'function getPosId(' not in content:
    content = content.replace('contract FHEPoolTest is Test {', 'contract FHEPoolTest is Test {' + helper)

with open('test/unit/FHEPool.t.sol', 'w') as f:
    f.write(content)
