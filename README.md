# ShadeSpot — FHE-Encrypted Perpetuals Protocol

ShadeSpot is a perpetuals trading protocol with two independent liquidity pools. All position data (size, collateral, entry price, direction) is kept encrypted on-chain using Fully Homomorphic Encryption (CoFHE). PnL, funding fees, and liquidation checks are computed entirely in the encrypted domain. Only a single settlement amount and one liquidation boolean are decrypted — and only at the moment they are needed.

---

## Two Pools

| | Pool 1 | Pool 2 |
|---|---|---|
| Collateral | USDC (standard ERC-20) | FHE Token (Fhenix FHERC20) |
| Trade token | ETH | ETH |
| Vault | `Vault.sol` — plaintext LP accounting | `FHEVault.sol` — encrypted LP accounting (`euint64`) |
| Entry point | `Router.sol` | `FHERouter.sol` |
| Token transfers | Standard `transferFrom` / `approve` | `confidentialTransferFrom` / `setOperator` |
| LP balances visible? | Yes | No — stored as `euint64` ciphertexts |

Both pools share the same `PositionManager`, `FundingRateManager`, `LiquidationManager`, and `OrderManager` logic. The `IVault` interface makes `PositionManager` work with either vault interchangeably.

---

## Architecture

```
                            POOL 1                              POOL 2
                       (USDC / ETH)                       (FHE Token / ETH)

  Trader ──────────► Router.sol                    Trader ──────────► FHERouter.sol
                          │                                                 │
                    (ERC-20 transferFrom)                    (confidentialTransferFrom)
                          │                                                 │
                          ▼                                                 ▼
                     Vault.sol                                        FHEVault.sol
                  (plaintext pool)                              (encrypted euint64 pool)
                          │                                                 │
                          └───────────────┬─────────────────────────────────┘
                                          │
                                          ▼
                                  PositionManager.sol
                              (FHE-encrypted positions)
                              euint128 size / collateral
                              euint128 entryPrice
                              ebool    isLong
                                          │
                          ┌───────────────┼───────────────┐
                          ▼               ▼               ▼
                   PriceOracle   FundingRateManager  LiquidationManager
                                                            │
                                                     OrderManager.sol
                                                  (limit / trigger orders)
```

---

## Repository Layout

```
contracts/
├── src/
│   ├── core/
│   │   ├── IVault.sol                # Common vault interface (Vault + FHEVault)
│   │   ├── Vault.sol                 # Pool 1 vault — plaintext ERC-20 LP accounting
│   │   ├── FHEVault.sol              # Pool 2 vault — encrypted euint64 LP accounting
│   │   ├── PositionManager.sol       # Position lifecycle; all fields encrypted (euint128 / ebool)
│   │   ├── FundingRateManager.sol    # OI accounting and hourly funding rate
│   │   └── LiquidationManager.sol   # Liquidation entry-point; delegates to PositionManager
│   ├── trading/
│   │   ├── Router.sol                # Pool 1 entry-point (standard ERC-20)
│   │   ├── FHERouter.sol             # Pool 2 entry-point (FHERC20 / confidential transfers)
│   │   └── OrderManager.sol         # Limit / trigger orders with encrypted trigger price
│   ├── oracle/
│   │   └── PriceOracle.sol           # Simple price feed (setPrice / getPrice)
│   ├── tokens/
│   │   ├── IEncryptedERC20.sol       # Interface for FHERC20 tokens (operator model)
│   │   ├── MockUSDC.sol              # 6-decimal ERC-20 for Pool 1 dev / testing
│   │   └── MockFHEToken.sol          # FHERC20 token for Pool 2 dev / testing
│   └── libraries/
│       └── PnlUtils.sol              # Plaintext PnL helpers (fuzz tests / off-chain)
│
├── test/
│   ├── unit/
│   │   ├── FHEPool.t.sol             # 33 tests: Pool 2 FHE token interactions end-to-end
│   │   ├── PositionManager.t.sol     # Open / close / PnL / funding unit tests
│   │   ├── LiquidationManager.t.sol  # Liquidation reward, solvency, revert-when-healthy
│   │   ├── OrderManager.t.sol        # Create / cancel / execute limit orders
│   │   ├── FundingRateManager.t.sol  # OI accounting and rate computation
│   │   ├── Vault.t.sol               # Deposit / withdraw / reserve / release (Pool 1)
│   │   └── PnlUtils.t.sol            # Library edge cases
│   ├── integration/
│   │   └── UserFlow.t.sol            # End-to-end: open→close profit/loss, liquidation, LP flows
│   ├── invariant/
│   │   └── InvariantTest.t.sol       # Vault solvency invariant (totalLiquidity ≥ totalReserved)
│   ├── fuzz/
│   │   ├── PnlUtils.t.sol            # Fuzz PnL library
│   │   └── FundingRateManager.t.sol  # Fuzz funding rate bounds
│   └── mocks/
│       └── MockTaskManager.sol       # Drop-in CoFHE TaskManager for Foundry (handle = plaintext)
│
├── script/
│   ├── Deploy.s.sol                  # Pool 1 only deployment
│   └── DeployDualPool.s.sol          # Both pools from one script
│
├── lib/
│   ├── cofhe-contracts/              # CoFHE FHE library (euint128, ebool, FHE.*)
│   ├── fhenix-confidential-contracts/# Fhenix FHERC20 base contract (euint64 balances)
│   ├── forge-std/
│   └── openzeppelin-contracts/
│
└── foundry.toml
```

---

## FHE Privacy Model

| Data | Encrypted type | When decrypted |
|---|---|---|
| Position size | `euint128` | At close / liquidation (to release vault reserves) |
| Collateral | `euint128` | At liquidation (to compute reward) |
| Entry price | `euint128` | Never — all PnL math runs in FHE |
| Direction (isLong) | `ebool` | Never |
| Trigger price (orders) | `euint128` | At order execution check |
| Can-liquidate flag | `ebool` | Single-bit decrypt gating the liquidation |
| Net settlement | `euint128` | Final amount sent to trader at close |
| Pool 2 LP balance | `euint64` | Only when LP withdraws (encrypted ≥ check, one bit) |
| Pool 2 totalLiquidity | `euint64` | Never exposed as plaintext |

---

## Components

### Router — `trading/Router.sol` (Pool 1)
Entry-point for Pool 1. Accepts USDC as collateral via standard `transferFrom` / `approve`. Enforces that only the configured `indexToken` (ETH) can be used as the trade token.

Actions: `openPosition`, `closePosition`, `createOrder`, `cancelOrder`, `executeOrder`, `addLiquidity`, `removeLiquidity`.

### FHERouter — `trading/FHERouter.sol` (Pool 2)
Entry-point for Pool 2. Accepts an FHERC20 token as collateral via `confidentialTransferFrom`. Users must call `fheToken.setOperator(address(fheRouter), untilTimestamp)` once before their first trade. Enforces the same `indexToken` guard as Router.

### PositionManager — `core/PositionManager.sol`
Owns the encrypted position lifecycle for both pools (via the `IVault` interface). All sensitive fields (`size`, `collateral`, `entryPrice`, `isLong`) are stored as FHE ciphertexts. PnL and funding fees are computed entirely in the encrypted domain via `FHE.mul` / `FHE.div` / `FHE.select`. Only one settlement value is decrypted per close, and one boolean per liquidation.

### IVault — `core/IVault.sol`
Common interface implemented by both `Vault` and `FHEVault`. Allows `PositionManager` to call `reserveLiquidity`, `releaseLiquidity`, `payTrader`, `receiveLoss`, and `refundCollateral` without knowing which pool it is operating on.

### Vault — `core/Vault.sol` (Pool 1)
Holds Pool 1 liquidity. `totalLiquidity` and `totalReserved` are plaintext `uint256`. Pays trader profits and absorbs losses. LP balances tracked per LP address.

### FHEVault — `core/FHEVault.sol` (Pool 2)
Holds Pool 2 liquidity with encrypted accounting. `totalLiquidity`, `totalReserved`, and all `lpBalance` values are `euint64` ciphertexts — on-chain observers cannot read pool depth or any LP's share. All encrypted checks use `FHE.getDecryptResultSafe` (decrypts one bit to gate requires).

### FundingRateManager — `core/FundingRateManager.sol`
Tracks long and short open interest per token. Computes a funding rate every hour proportional to the OI imbalance. Longs pay shorts when longs dominate, and vice versa.

### LiquidationManager — `core/LiquidationManager.sol`
Entry-point for liquidator bots. Updates funding then delegates to `PositionManager.liquidate()`, which runs the encrypted loss check (decrypts one bit), settles the vault, and pays the 5% liquidator reward directly to the caller.

### OrderManager — `trading/OrderManager.sol`
Stores limit / trigger orders. Trigger price stored as `euint128`. Execution checks whether the oracle price has crossed the trigger using FHE comparison. Orders are activated by a keeper via `executeOrder`.

### PriceOracle — `oracle/PriceOracle.sol`
Simple price feed. `setPrice(token, price)` / `getPrice(token)`. Intended to be replaced with a Chainlink / Pyth adapter in production.

---

## Tokens

### MockUSDC — `tokens/MockUSDC.sol`
6-decimal ERC-20 (`1 USDC = 1e6`). Used as Pool 1 collateral in tests and local deployments. No access control on `mint` / `burn`.

### MockFHEToken — `tokens/MockFHEToken.sol`
Extends Fhenix `FHERC20` (from `fhenix-confidential-contracts`). Stores balances as `euint64` ciphertexts. Standard `transfer` / `transferFrom` / `approve` deliberately revert — use `confidentialTransfer` / `confidentialTransferFrom` instead. Used as Pool 2 collateral in tests and local deployments.

### IEncryptedERC20 — `tokens/IEncryptedERC20.sol`
Interface that `FHERouter` and `FHEVault` use to interact with any FHERC20-compatible token. Covers `setOperator`, `isOperator`, `confidentialTransfer`, and `confidentialTransferFrom`.

---

## Running Tests

```bash
forge test                                          # all 80 tests
forge test -v                                       # verbose output
forge test --match-path test/unit/FHEPool.t.sol    # Pool 2 FHE tests only (33 tests)
forge test --match-test test_Flow_Liquidation       # single test by name
forge test --match-contract InvariantTest           # invariant suite
```

The `MockTaskManager` is etched at the CoFHE `TASK_MANAGER_ADDRESS` in each test's `setUp`. It uses a handle-equals-plaintext strategy — `trivialEncrypt(x)` returns `x` as the handle, and `getDecryptResultSafe(h)` returns `(h, true)` — enabling synchronous FHE testing in Foundry with no coprocessor.

---

## Deployment

### Pool 1 only

```bash
export PRIVATE_KEY=0x...
export INDEX_TOKEN=0x...          # ETH token address (used for oracle + position keys)
# COLLATERAL_TOKEN is optional — if unset, MockUSDC is deployed automatically
forge script script/Deploy.s.sol --rpc-url <RPC_URL> --broadcast
```

### Both pools (recommended)

```bash
export PRIVATE_KEY=0x...
export INDEX_TOKEN=0x...          # ETH token address
# COLLATERAL_TOKEN_USDC and COLLATERAL_TOKEN_FHE are optional
# If unset, MockUSDC and MockFHEToken are deployed automatically
forge script script/DeployDualPool.s.sol --rpc-url <RPC_URL> --broadcast
```

To use real tokens on a live network, set the optional env vars:

```bash
export COLLATERAL_TOKEN_USDC=0x...   # real USDC address
export COLLATERAL_TOKEN_FHE=0x...    # real FHERC20 address
```

### Pool 2 operator setup (users)

Before trading or adding liquidity to Pool 2, each user must grant the `FHERouter` operator status on the FHE token:

```solidity
fheToken.setOperator(address(fheRouter), type(uint48).max);
```

This replaces the `approve` step from standard ERC-20.

---

## Build

```bash
forge build
```

`via_ir = true` is required in `foundry.toml` to avoid stack-too-deep errors in `PositionManager`.
