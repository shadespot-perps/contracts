# ShadeSpot — FHE-Encrypted Perpetuals Protocol

ShadeSpot is a perpetuals trading protocol where all position data (size, collateral, entry price, direction) is kept encrypted on-chain using Fully Homomorphic Encryption (CoFHE). PnL, funding fees, and liquidation checks are computed entirely in the encrypted domain. Only a single settlement amount and one liquidation boolean are decrypted — and only at the moment they are needed.

## Architecture

```
                    +----------------------+
                    |     PriceOracle      |
                    |   (oracle/Price      |
                    |    Oracle.sol)       |
                    +----------+-----------+
                               |
                               v
+-------------+      +----------------------+      +----------------------+
|   Trader    | ---> |        Router        | ---> |   PositionManager    |
+-------------+      |  (trading/Router)    |      |   (core/Position     |
                     +----------+-----------+      |    Manager.sol)      |
                                |                  +----------+-----------+
                                |                             |
                     +----------v-----------+                 v
                     |    OrderManager      |      +----------------------+
                     | (trading/OrderMgr)   |      | FundingRateManager   |
                     | Encrypted trigger    |      | (core/FundingRate    |
                     | prices (euint128)    |      |  Manager.sol)        |
                     +----------------------+      +----------+-----------+
                                                              |
                     +----------------------------------------v-----------+
                     |                     Vault                          |
                     |               (core/Vault.sol)                     |
                     |         Liquidity pool — holds all assets          |
                     +----------------------------------------------------+
                                |                        |
                     +----------v---------+    +---------v---------+
                     |   Liquidity LPs    |    | LiquidationManager|
                     +--------------------+    | (core/Liquidation  |
                                               |  Manager.sol)      |
                                               +--------------------+
```

## Repository Layout

```
contracts/
├── src/
│   ├── core/
│   │   ├── PositionManager.sol      # Position lifecycle; all fields encrypted (euint128 / ebool)
│   │   ├── Vault.sol                # Liquidity pool; pays profits and receives losses
│   │   ├── FundingRateManager.sol   # Open-interest accounting and hourly funding rate
│   │   └── LiquidationManager.sol  # Thin liquidation entry-point; delegates to PositionManager
│   ├── trading/
│   │   ├── Router.sol               # Protocol entry-point for all user actions
│   │   └── OrderManager.sol        # Limit / trigger orders with encrypted trigger price
│   ├── oracle/
│   │   └── PriceOracle.sol          # Simple price feed (setPrice / getPrice)
│   └── libraries/
│       └── PnlUtils.sol             # Plaintext PnL helpers used by fuzz tests
│
├── test/
│   ├── unit/
│   │   ├── PositionManager.t.sol    # Open / close / PnL / funding unit tests
│   │   ├── LiquidationManager.t.sol # Liquidation reward, solvency, revert-when-healthy
│   │   ├── OrderManager.t.sol       # Create / cancel / execute limit orders
│   │   ├── FundingRateManager.t.sol # OI accounting and rate computation
│   │   ├── Vault.t.sol              # Deposit / withdraw / reserve / release
│   │   └── PnlUtils.t.sol           # Library edge cases
│   ├── integration/
│   │   └── UserFlow.t.sol           # End-to-end: open→close profit/loss, liquidation, LP flows
│   ├── invariant/
│   │   └── InvariantTest.t.sol      # Vault solvency invariant (totalLiquidity ≥ totalReserved)
│   ├── fuzz/
│   │   ├── PnlUtils.t.sol           # Fuzz PnL library
│   │   └── FundingRateManager.t.sol # Fuzz funding rate bounds
│   └── mocks/
│       └── MockTaskManager.sol      # Drop-in CoFHE TaskManager for Foundry (handle = plaintext)
│
├── lib/
│   ├── cofhe-contracts/             # CoFHE FHE library (euint128, ebool, FHE.*)
│   ├── forge-std/
│   └── openzeppelin-contracts/
│
└── foundry.toml
```

## FHE Privacy Model

| Data | Encrypted? | When decrypted |
|------|-----------|---------------|
| Position size | `euint128` | At close / liquidation (to release vault reserves) |
| Collateral | `euint128` | At liquidation (to compute reward) |
| Entry price | `euint128` | Never decrypted; all PnL math runs in FHE |
| Direction (isLong) | `ebool` | Never |
| Trigger price (orders) | `euint128` | At order execution check |
| Can-liquidate flag | `ebool` | Single-bit decrypt gating the liquidation |
| Net settlement | `euint128` | Final amount sent to trader at close |

## Components

### Router — `trading/Router.sol`
Single entry-point for all user actions. Coordinates funding updates, collateral transfers, and delegates to PositionManager and OrderManager.

Actions: `openPosition`, `closePosition`, `createOrder`, `cancelOrder`, `executeOrder`, `addLiquidity`, `removeLiquidity`.

### PositionManager — `core/PositionManager.sol`
Owns the encrypted position lifecycle. All sensitive fields (`size`, `collateral`, `entryPrice`, `isLong`) are stored as FHE ciphertexts. PnL and funding fees are computed entirely in the encrypted domain via `FHE.mul` / `FHE.div` / `FHE.select`. Only one settlement value is decrypted per close, and one boolean per liquidation.

### Vault — `core/Vault.sol`
Holds the liquidity pool. Tracks `totalLiquidity` and `totalReserved`. Pays trader profits (`payTrader`), absorbs losses (`receiveLoss`), and manages LP deposits.

### FundingRateManager — `core/FundingRateManager.sol`
Tracks long and short open interest per token. Computes a funding rate every hour proportional to the OI imbalance. Longs pay shorts when longs dominate, and vice versa.

### LiquidationManager — `core/LiquidationManager.sol`
Thin entry-point for liquidator bots. Updates funding then delegates fully to `PositionManager.liquidate()`, which runs the encrypted loss check (decrypts one bit), settles the vault, and pays the 5% liquidator reward directly to the caller.

### OrderManager — `trading/OrderManager.sol`
Stores limit / trigger orders. The trigger price is stored as `euint128`. Execution checks whether the oracle price has crossed the trigger using FHE comparison; orders are activated by a keeper via `executeOrder`.

### PriceOracle — `oracle/PriceOracle.sol`
Simple price feed. `setPrice(token, price)` / `getPrice(token)`. Intended to be replaced with a Chainlink / Pyth adapter in production.

### PnLUtils — `libraries/PnlUtils.sol`
Plaintext PnL library (used by fuzz tests and off-chain tooling). Not used in the on-chain encrypted path.

## Running Tests

```bash
forge test              # all tests
forge test -v           # verbose output
forge test --match-test test_Flow_Liquidation   # single test
forge test --match-contract InvariantTest       # invariant suite
```

The `MockTaskManager` is etched at the CoFHE `TaskManager` address in each test's `setUp`. It uses a handle-equals-plaintext strategy with a non-zero false sentinel (`2`) so the FHE library's `isInitialized` check works correctly.

## Build

```bash
forge build
```

`via_ir = true` is required in `foundry.toml` to avoid stack-too-deep errors in `PositionManager`.
