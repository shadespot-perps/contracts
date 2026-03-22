# My_Perpetuals — Technical Architecture

> Solidity `^0.8.20` · Foundry · OpenZeppelin ERC-20 · Single-collateral perpetual DEX

---

## 1. System Overview

My_Perpetuals is a **single-collateral, on-chain perpetual futures DEX**. It uses a **peer-to-pool (P2Pool)** model: LPs deposit a single ERC-20 token into `Vault`, which acts as the unified counterparty for all trader positions. There is no AMM, no order book matching — the pool always takes the other side.

The protocol is composed of **8 contracts** across three layers:

| Layer | Contracts |
|-------|-----------|
| **Trading (Entry)** | `Router`, `OrderManager` |
| **Core (State)** | `PositionManager`, `Vault`, `FundingRateManager`, `LiquidationManager` |
| **Infrastructure** | `PriceOracle`, `PnLUtils` (library) |

---

## 2. Contract Dependency Graph

```
                         ┌─────────────────────┐
                         │       Router         │  ← trader/keeper entry point
                         └──┬──────────┬────────┘
                            │          │
               ┌────────────▼──┐   ┌───▼──────────────┐
               │ PositionManager│   │  OrderManager     │
               └──┬──┬──┬──────┘   └───┬───────────────┘
                  │  │  │              │
         ┌────────┘  │  └──────────────┼──────────┐
         │           │                │           │
    ┌────▼───┐  ┌────▼──────────┐  ┌──▼──────┐   │
    │ Vault  │  │FundingRateMgr │  │PriceOracle│  │
    └────────┘  └───────────────┘  └─────────┘   │
         ▲                                        │
         │                                        │
    ┌────┴──────────────────────── ───────────────┘
    │   LiquidationManager
    │   (reads PositionManager, oracle, fundingMgr; writes to Vault via PositionManager.liquidate())
    └──────────────────────────────────────────────
```

**Trust model** — Each contract enforces a strict caller whitelist:

- `Vault` accepts LP/position mutations only from `router` or `positionManager`.
- `PositionManager` accepts position mutations only from `router` or `liquidationManager`.
- `FundingRateManager` funding updates only from `router`; OI updates only from `positionManager`.
- `OrderManager` writes only from `router`.

All privilege addresses are set **once** (enforced by `require(addr == address(0))` guards) and cannot be rotated without owner re-deployment — this is a current centralization risk.

---

## 3. Contract Deep-Dives

### 3.1 `Vault.sol` — Liquidity Custodian

**State:**
```solidity
IERC20 public immutable collateralToken;  // single ERC-20 (e.g., USDC)
uint256 public totalLiquidity;            // gross LP deposits + realized trader losses + funding income
uint256 public totalReserved;             // sum of all open position sizes (max-loss reservation)
mapping(address => uint256) public lpBalance;
```

**Key invariant:**
```
availableLiquidity() = totalLiquidity - totalReserved ≥ 0
```

Withdrawals and new payouts both check `availableLiquidity()` before execution. This means the vault can never become technically insolvent at the token-transfer level (it may still have gap risk if `totalReserved > totalLiquidity` in a market gap, but deposits are always in-token).

**LP Shares:** Currently **not tokenized** — `lpBalance` is a plain `uint256` mapping. There is no ERC-20 LP token, no fee accrual mechanism per share. LP PnL is implicit: when traders lose, `totalLiquidity` grows via `receiveLoss()`; when traders profit, the vault pays out from the pool, shrinking `totalLiquidity`.

**Profit, Funding, and Refund flow to vault:**
- `Vault.receiveLoss()` — increases `totalLiquidity` when a trader physically loses collateral or pays net funding fees backwards into the LP pool.
- `Vault.payTrader()` — safely processes trader winnings (price profit + funding receipts) by explicitly decreasing `totalLiquidity` before transferring out. *Note: this function dynamically caps the trader payout to the Vault's current `availableLiquidity()`, mathematically preventing LP front-running and infinite-profit lockups.*
- `Vault.refundCollateral()` — exclusively used to return un-utilized escrowed collateral directly to the user (e.g. limit order cancellations).

---

### 3.2 `PositionManager.sol` — Core State Machine

**Position struct:**
```solidity
struct Position {
    address owner;
    address indexToken;
    uint256 size;            // notional = collateral * leverage (in collateral token units)
    uint256 collateral;      // deposited margin
    uint256 entryPrice;      // oracle price at open (raw uint256, assumed 1e18 or fixed precision)
    int256 entryFundingRate; // snapshot of cumulativeFundingRate at open
    bool isLong;
}
```

**Position key:** `keccak256(abi.encode(trader, indexToken, isLong))`
→ One position per (trader, token, direction) tuple. You cannot stack multiple independent longs on the same token.

**Max leverage:** `MAX_LEVERAGE = 10x` (enforced at open)

**Liquidation threshold:** `LIQUIDATION_THRESHOLD = 80%` — a position is liquidatable when losses exceed 80% of its collateral.

#### Open Position Flow

```
Router.openPosition(token, collateral, leverage, isLong)
  │
  ├─ collateralToken.transferFrom(trader → vault)
  ├─ fundingManager.updateFunding(token)          ← must run before snapshot
  │
  └─ PositionManager.openPosition(...)
       ├─ size = collateral * leverage
       ├─ price = oracle.getPrice(token)
       ├─ fundingRate = fundingManager.getFundingRate(token)
       ├─ vault.reserveLiquidity(size)             ← locks max payout capacity
       └─ positions[key] = Position{...}
           └─ fundingManager.increaseOpenInterest(token, size, isLong)
```

#### Close Position Flow

```
Router.closePosition(token, isLong)
  │
  ├─ fundingManager.updateFunding(token)
  │
  └─ PositionManager.closePosition(...)
       ├─ price = oracle.getPrice(token)
       ├─ pnl = calculatePnL(position, price)
       ├─ fundingFee = calculateFundingFee(position)
       ├─ pnl -= fundingFee                        ← net PnL after funding cost (can increase PnL if receiving funding)
       ├─ vault.releaseLiquidity(position.size)
       │
       ├─ if pnl > 0:
       │     vault.payTrader(trader, profit, collateral)
       │
       └─ if pnl < 0:
             loss = -pnl
             if loss >= collateral:
               vault.receiveLoss(collateral)        ← trader wiped out
             else:
               vault.receiveLoss(loss)
               vault.payTrader(trader, 0, collateral - loss)
```

**Note on `receiveLoss()`:** This function only increments `totalLiquidity` — it does **not** move tokens. The collateral was already deposited into `Vault` at position open (sent by `Router`), so the accounting update is all that is needed. This is sound but subtle: the vault holds the collateral physically from the moment of `transferFrom`.

#### PnL Formula

For **long** positions:
```
PnL = (currentPrice - entryPrice) * size / entryPrice
```

For **short** positions:
```
PnL = (entryPrice - currentPrice) * size / entryPrice
```

Both return `int256` (signed). The formula normalizes PnL back to collateral-token units. **Important precision note:** `size` and `entryPrice` must share the same decimal base for this ratio to cancel correctly — there is no explicit decimal validation in the current code.

---

### 3.3 `FundingRateManager.sol` — Funding Accumulator

**Per-token state:**
```solidity
struct FundingData {
    int256 cumulativeFundingRate;   // signed accumulator (positive = longs pay, negative = shorts pay)
    uint256 lastFundingTime;
    uint256 longOpenInterest;       // sum of all long position sizes
    uint256 shortOpenInterest;      // sum of all short position sizes
}
```

**Funding rate epoch:** `FUNDING_INTERVAL = 1 hour`

**Rate computation per epoch:**
```
imbalance = |longOI - shortOI|
totalOI   = longOI + shortOI

// Rate is explicitly signed depending on which side has majority
int256 signedRate;
if (longOI >= shortOI) {
    uint256 imbalance = longOI - shortOI;
    signedRate = int256((imbalance * FUNDING_RATE_PRECISION) / totalOI);
} else {
    uint256 imbalance = shortOI - longOI;
    signedRate = -int256((imbalance * FUNDING_RATE_PRECISION) / totalOI);
}
cumulativeFundingRate  += signedRate
```

`FUNDING_RATE_PRECISION = 1e12`

This is an **imbalance-proportional** two-sided funding model. The rate is explicitly signed (positive when longs dominate, negative when shorts dominate). The Vault serves as the central counterparty bridging the cash flows.

**Funding fee at close:**
```solidity
int256 fundingDiff = cumulativeFundingRate_now - position.entryFundingRate;
int256 feeBase = (int256(position.size) * fundingDiff) / int256(FUNDING_PRECISION);
int256 fundingFee = position.isLong ? feeBase : -feeBase;
```

Because `fundingFee` can be negative, traders can **receive funding**, which increases their net PnL prior to `Vault.payTrader()` execution. The Vault's total LP liquidity mathematically shrinks or grows as the net aggregate counterparty.

**Important:** `updateFunding()` is idempotent within a 1-hour window (early return if `block.timestamp < lastFundingTime + FUNDING_INTERVAL`). The function is fully **public (unpermissioned)**, meaning any caller (including `OrderManager` triggers) can safely tick the deterministic time-clock forward regardless of how many trades occur.

---

### 3.4 `LiquidationManager.sol` — Permissionless Liquidator

Anyone can call `liquidate()`. The protocol implements an **incentivized liquidation** model:

**Liquidator reward:** `LIQUIDATION_BONUS = 5%` of the position's collateral

**Liquidation check:**
```
isLiquidatable = true  iff:
  pnl < 0
  AND
  loss >= (collateral * 80) / 100
```

**Execution sequence:**
```
LiquidationManager.liquidate(trader, token, isLong)
  ├─ isLiquidatable(...) check
  ├─ fundingManager.updateFunding(token)         ← ensure funding is current
  └─ positionManager.liquidate(trader, token, isLong)
       ├─ re-verifies threshold internally        ← double-check (defense in depth)
       ├─ vault.releaseLiquidity(size)
       ├─ vault.receiveLoss(collateral - reward)   ← remaining collateral flows to pool
       ├─ vault.payTrader(liquidationManager, 0, reward)  ← 5% bonus paid out internally
       └─ vault.collateralToken().transfer(liquidator, reward) ← bonus forwarded cleanly to caller
```

**Design note:** The 5% liquidator reward is executed natively inside `PositionManager.liquidate`. The liquidator is paid *directly* out of the seized collateral prior to the remainder being passed to the LP pool (`vault.receiveLoss`). This guarantees liquidations can never be deadlocked by a 100% Vault utilization rate.

---

### 3.5 `Router.sol` — Unified Entry Point

The Router is the only contract that:
1. Pulls `collateralToken` from the user (`transferFrom`) before passing control.
2. Triggers `fundingManager.updateFunding()` before every state-mutating call.
3. Dispatches to `PositionManager` or `Vault` or `OrderManager`.

**Limit order flow:**
```
Router.createOrder(token, collateral, leverage, triggerPrice, isLong)
  ├─ collateralToken.transferFrom(trader → vault)  ← collateral locked immediately
  └─ orderManager.createOrder(...)                ← order stored as pending

Router.executeOrder(orderId)   ← called by keeper
  ├─ orderManager.executeOrder(orderId)
  │    ├─ oracle.getPrice(token)
  │    ├─ if isLong:  require(price <= triggerPrice)
  │    └─ if isShort: require(price >= triggerPrice)
  ├─ fundingManager.updateFunding(token)
  └─ positionManager.openPosition(trader, ...)
```

**LP functions:**
```
addLiquidity(amount):
  transferFrom(user → vault) → vault.deposit(amount)

removeLiquidity(amount):
  vault.withdraw(amount)      ← checks lpBalance[msg.sender] and availableLiquidity()
```

Note: `vault.deposit()` and `vault.withdraw()` are gated `onlyRouter`, so LPs cannot interact with `Vault` directly.

---

### 3.6 `OrderManager.sol` — Limit Order Book

Simple sequential ID book (`nextOrderId` counter). Each order stores:

```solidity
struct Order {
    address trader;
    address token;
    uint256 collateral;
    uint256 leverage;
    uint256 triggerPrice;
    bool isLong;
    bool isActive;
}
```

**Execution conditions:**
- Long order: executes when `oracle.getPrice(token) <= triggerPrice` (buy dip)
- Short order: executes when `oracle.getPrice(token) >= triggerPrice` (sell rally)

Orders are not matched peer-to-peer — they are keeper-executed against the pool, identical to a market order once the price condition is met.

*(Note: The previous limit order cancellation bug where trader identity was incorrectly checked has been formally patched and collateral is now safely refunded by the Router).*

---

### 3.7 `PriceOracle.sol` — Owner-Settable Price Feed

```solidity
uint256 public constant MAX_PRICE_DELAY = 5 minutes;
```

`setPrice(token, price)` is callable only by `owner`. This is a **centralized/simulated oracle** — there is no Chainlink or Pyth integration yet. Stale-price protection reverts if `block.timestamp > lastUpdated + 5 minutes`.

**Production gap:** A single owner-controlled price feed introduces significant manipulation risk (front-running, sandwich, oracle manipulation). Migration path should integrate a pull-based oracle (Pyth) or a Chainlink price feed with heartbeat validation.

---

### 3.8 `PnLUtils.sol` — Stateless Library

A pure Solidity library mirroring the PnL calculation in `PositionManager`. Provides three functions:

| Function | Returns |
|----------|---------|
| `calculatePnL(position, price)` | `int256` signed PnL |
| `isProfit(position, price)` | `bool` |
| `getLoss(position, price)` | `uint256` absolute loss |
| `getProfit(position, price)` | `uint256` absolute profit |

**Note:** `PnLUtils` is currently not imported by any other contract in the repo — `PositionManager` and `LiquidationManager` both duplicate the PnL math inline. It exists as a standalone utility but is not wired into the live system.

---

## 4. Key Protocol Mechanics

### 4.1 Liquidity Reservation Model

When a position opens, `vault.reserveLiquidity(size)` books the full notional as a potential max-loss obligation. This is conservative: a 10x leveraged position on USDC-denominated prices reserves 10x the collateral even though the asset price cannot go to zero in practice. Utilization is:

```
utilization = totalReserved / totalLiquidity
```

If `utilization = 100%`, no new positions can open and no LPs can withdraw. There is no cap mechanism to throttle large positions before hitting the ceiling.

### 4.2 Funding Settlement Timing

Funding is settled lazily:

1. `updateFunding(token)` is called at every Router entry point (open, close, executeOrder, addLiquidity).
2. The accumulator only ticks once per hour.
3. Funding fee is **deducted from PnL at close**, not streamed continuously.

This means a trader can hold a position for 24 hours and pay 24 accumulated funding epochs in one shot at close — there is no mid-position funding margin call.

### 4.3 Collateral Flow Summary

```
LP Flow:
  LP → Router.addLiquidity() → Vault.deposit()
  ERC-20 path: LP wallet → Vault contract address

Trader Open:
  Trader → Router.openPosition() → Vault (via transferFrom)
  ERC-20 path: Trader wallet → Vault contract address
  (collateral is physically in vault from block of open)

Trader Close (profit):
  Vault.payTrader(trader, profit, collateral)  → totalLiquidity -= profit
  ERC-20 path: Vault → Trader wallet

Trader Close (loss):
  Vault.receiveLoss(loss)      → totalLiquidity += loss  (accounting only, no token move)
  Vault.payTrader(trader, 0, remainder)

Liquidation:
  PositionManager.liquidate() 
    → vault.receiveLoss(collateral - reward)  (accounting to pool)
    → vault.payTrader(liquidator, 0, reward)  (token move directly to liquidator)
```

---

## 5. Access Control Matrix

| Caller \ Target | `Vault` | `PositionManager` | `FundingRateMgr` | `OrderManager` |
|---|---|---|---|---|
| `Router` | `deposit`, `withdraw`, `refundCollateral` | `openPosition`, `closePosition` | *None (see Public)* | `createOrder`, `cancelOrder`, `executeOrder` |
| `PositionManager` | `reserveLiquidity`, `releaseLiquidity`, `payTrader`, `receiveLoss` | — | `increaseOI`, `decreaseOI` | — |
| `LiquidationManager` | — | `liquidate` | — | — |
| `Owner` | `setPositionManager`, `setRouter` | `setRouter`, `setLiquidationManager` | `setRouter`, `setPositionManager` | `setRouter` |
| `Public/Keeper` | — | — | `updateFunding` | — (only via Router) |

---

## 6. Known Risks & Design Gaps

| # | Issue | Location | Severity |
|---|-------|----------|----------|
| 1 | **Centralized oracle** — owner sets prices; no TWAP, no Chainlink | `PriceOracle.sol` | Critical |
| 2 | ~~**Cancel order broken**~~ [PATCHED via Router returning caller pool collateral] | `OrderManager.sol` | Resolved |
| 3 | **No LP tokenization** — LP positions are not transferable; no share-based fee accounting | `Vault.sol` | Medium |
| 4 | **No position modification** — no increase/decrease collateral or size; full open/close only | `PositionManager.sol` | Low |
| 5 | **Single address per direction** — `keccak256(trader, token, isLong)` key prevents multiple independent positions | `PositionManager.sol:107` | Low |
| 6 | **PnLUtils unused** — library exists but not integrated | `PnlUtils.sol` | Low |
| 7 | **Precision assumptions** — oracle price units and collateral units are not validated to share scale | `PositionManager.sol:222-231` | Medium |
| 8 | **Immutable privilege addresses** — PM/Router addresses can only be set once; no upgrade path | `Vault.sol:51,57` | Medium |

---

## 7. Deployment Configuration

- **Framework:** Foundry (`foundry.toml`)
- **Solidity:** `^0.8.20`
- **Dependencies:** OpenZeppelin (`@openzeppelin/contracts`) via git submodule (`lib/`)
- **Scripts:** `/script/` (deployment scripts)
- **Tests:** `/test/` (Foundry test suite)

**Deployment order (dependency-respecting):**
1. `PriceOracle` (no dependencies)
2. `FundingRateManager` (no dependencies)
3. `Vault(collateralToken, owner)`
4. `PositionManager(vault, oracle, fundingManager)`
5. `OrderManager(oracle, fundingManager, owner)`
6. `Router(positionManager, vault, orderManager, fundingManager, collateralToken)`
7. `LiquidationManager(positionManager, oracle, vault, fundingManager)`
8. Admin wiring:
   - `vault.setPositionManager(positionManager)`
   - `vault.setRouter(router)`
   - `positionManager.setRouter(router)`
   - `positionManager.setLiquidationManager(liquidationManager)`
   - `fundingManager.setRouter(router)`
   - `fundingManager.setPositionManager(positionManager)`
   - `orderManager.setRouter(router)`
