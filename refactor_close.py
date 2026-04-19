import re

with open('src/core/PositionManager.sol', 'r') as f:
    content = f.read()

old_func = """    function requestClosePosition(
        address trader,
        address token,
        bool isLong
    ) external onlyRouter {

    bytes32 key = _traderPositionKey[trader][token][isLong];
    Position storage position = positions[key];"""

new_func = """    function requestClosePosition(
        address trader,
        address token,
        bool isLong
    ) external onlyRouter {
        bytes32 key = _traderPositionKey[trader][token][isLong];
        _requestClosePosition(key, trader, token);
    }

    function requestClosePositionFHE(
        address trader,
        bytes32 positionId
    ) external onlyFHERouter {
        _requestClosePosition(positionId, trader, positions[positionId].indexToken);
    }

    function _requestClosePosition(bytes32 key, address trader, address token) internal {
    Position storage position = positions[key];"""

if old_func in content:
    content = content.replace(old_func, new_func)
    with open('src/core/PositionManager.sol', 'w') as f:
        f.write(content)
else:
    print("Could not find the target string in PositionManager.sol")
    
