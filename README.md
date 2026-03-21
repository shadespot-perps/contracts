## Protocol Architecture Diagram
                    +----------------------+
                    |      Price Oracle    |
                    | (PriceOracle.sol)    |
                    +----------+-----------+
                               |
                               |
                               v
+-------------+      +----------------------+      +----------------------+
|   Trader    | ---> |        Router        | ---> |    PositionManager   |
+-------------+      |      (Router.sol)    |      |   (PositionManager)  |
                     +----------+-----------+      +----------+-----------+
                                |                             |
                                |                             |
                                v                             v
                        +---------------+           +--------------------+
                        | OrderManager  |           | FundingRateManager |
                        | (Limit Orders)|           | (Funding Logic)    |
                        +-------+-------+           +----------+---------+
                                |                              |
                                |                              |
                                v                              v
                          +-----------------------------------------+
                          |                 Vault                    |
                          |         (Liquidity Pool Storage)        |
                          +------------------+----------------------+
                                             |
                                             |
                                     +-------v-------+
                                     | Liquidity LPs |
                                     +---------------+
## What Each Component Does
### Router

Router.sol is the entry point of the protocol.

Every user action goes through it:

- open position

- close position

- create order

- add liquidity

Think of it like a controller.

User → Router → Other Contracts
Vault

Vault.sol stores all assets.

- Responsibilities:

Hold liquidity

Pay trader profits

Receive trader losses

Manage LP funds

LPs deposit → Vault
Traders PnL ← Vault
PositionManager

Handles trading logic.

- Responsibilities:

create position

update position

close position

store position data

Example position:

Position {
 trader
 size
 collateral
 entryPrice
 isLong
}
OrderManager

Handles limit orders / trigger orders.

Example order:

Order {
 trader
 collateral
 leverage
 triggerPrice
}

Keepers execute these orders.

## FundingRateManager

Handles perpetual funding mechanism.

Balances longs vs shorts.

Example:

Too many longs → longs pay shorts
Too many shorts → shorts pay longs
## PriceOracle

Provides market prices.

Used for:

PnL calculation

liquidation checks

funding rates

## Smart Contract Interaction Sequence

This shows step-by-step execution of a trade.

It is called a Sequence Diagram in software architecture.

### Example 1 — Opening a Position
User Action

Trader opens 10x BTC long

## Step-by-Step Smart Contract Calls
Trader
  |
  | openPosition()
  v
Router
  |
  | updateFunding()
  v
FundingRateManager
  |
  | getPrice()
  v
PriceOracle
  |
  | store position
  v
PositionManager
  |
  | transfer collateral
  v
Vault

## Detailed Call Sequence
1️⃣ Trader calls

Router.openPosition()

2️⃣ Router updates funding

FundingRateManager.updateFunding()

3️⃣ Router gets price

PriceOracle.getPrice()

4️⃣ Router opens position

PositionManager.openPosition()

5️⃣ Collateral transferred

Vault.depositCollateral()

## Example 2 — Closing Position
Trader
  |
  | closePosition()
  v
Router
  |
  | updateFunding()
  v
FundingRateManager
  |
  | getPrice()
  v
PriceOracle
  |
  | calculate pnl
  v
PnlUtils
  |
  | payout
  v
Vault

## Execution Steps
1️⃣ Trader calls closePosition()

2️⃣ Funding updated

3️⃣ Price fetched from oracle

4️⃣ PnL calculated

5️⃣ Position removed

6️⃣ Profit/loss settled from Vault

## Example 3 — Liquidation

Liquidator bots monitor unsafe positions.

Liquidator
  |
  | liquidate()
  v
LiquidationManager
  |
  | getPrice()
  v
PriceOracle
  |
  | check margin
  v
PositionManager
  |
  | close position
  v
Vault
## Liquidation Steps
1️⃣ Bot detects unsafe position

2️⃣ Calls liquidation function

3️⃣ Oracle price checked

4️⃣ Margin verified

5️⃣ Position force-closed

6️⃣ Liquidator receives reward

## Example 4 — Limit Order Execution
Trader
  |
  | createOrder()
  v
Router
  |
  v
OrderManager
  |
  (order stored)

Keeper Bot
  |
  | executeOrder()
  v
Router
  |
  v
PositionManager