with open('test/unit/PositionManager.t.sol', 'r') as f:
    text = f.read()

text = text.replace(
    'vault.setPendingReservation(trader, 500e18 * 5);',
    'vault.setPendingReservation(trader, 5000 * 1e18);'
)

with open('test/unit/PositionManager.t.sol', 'w') as f:
    f.write(text)
