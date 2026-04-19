# ShadeSpot — 100% FHE-Encrypted Perpetuals Protocol

ShadeSpot is a perpetuals trading protocol built entirely on Fully Homomorphic Encryption (CoFHE). By natively adopting a 100% Pure-FHE architecture, everything from trade execution (size, collateral, entry price, direction) to internal liquidity accounting and order limits is mathematically encrypted on-chain.

PnL, funding fees, cross-position balances, and liquidation checks are computed entirely in the encrypted domain without ever exposing plaintext data to the public mempool or state. Only the final settlement payout and a single liquidation boolean ever get decrypted—and only at the exact moment they are finalized.

---

## Architecture

ShadeSpot is structurally decoupled from legacy Ethereum plaintext constraints. The collateral token itself is an `FHERC20` Encrypted ERC-20 token, meaning observers cannot even see initial deposit sizes or vault balances.

```
                         SHADESPOT (Pure FHE)
                     (Encrypted FHERC20 Collateral)

  Trader ──────────► FHERouter.sol
                          │
             (confidentialTransferFrom / 0x0 data leaks)
                          │
                          ▼
                    FHEVault.sol
               (Total Liquidity = euint64)
               (Total Reserved = euint64)
                          │
                          └───────────────┬─────────────────────────────────┐
                                          │                                 │
                                          ▼                                 ▼
                                  PositionManager.sol               FHEOrderManager.sol
                              (FHE-encrypted positions)           (Encrypted limit/trigger)
                              euint128 size / collateral
                              euint128 entryPrice
                              ebool    isLong
                                          │
                          ┌───────────────┼───────────────┐
                          ▼               ▼               ▼
                   PriceOracle   FHEFundingRateManager  LiquidationManager
                 (Public price)  (euint128 tracking)   (Encrypted solvency)
```

---

## Repository Layout

```
contracts/
├── src/
│   ├── core/
│   │   ├── IVault.sol                # Vault routing interface
│   │   ├── FHEVault.sol              # FHE-Native vault — encrypted euint64 LP accounting
│   │   ├── PositionManager.sol       # Position lifecycle; all fields encrypted (euint128 / ebool)
│   │   ├── FHEFundingRateManager.sol # Encrypted OI accounting and hourly funding bounds
│   │   └── LiquidationManager.sol    # Liquidation entry-point; fully FHE solvent checking
│   ├── trading/
│   │   ├── FHERouter.sol             # Primary entry-point (FHERC20 / confidential transfers)
│   │   └── FHEOrderManager.sol       # Limit / trigger orders with encrypted trigger prices
│   ├── oracle/
│   │   └── PriceOracle.sol           # Simple price feed (setPrice / getPrice)
│   ├── tokens/
│   │   ├── IEncryptedERC20.sol       # Interface for FHERC20 tokens (operator model)
│   │   └── MockFHEToken.sol          # FHERC20 token for development / testing
│   └── libraries/
│       └── PnlUtils.sol              # Generic PnL helpers
│
├── test/
│   ├── unit/
│   │   ├── FHEPool.t.sol             # Extremely comprehensive 100% FHE end-to-end tests
│   │   └── PnlUtils.t.sol            # Library edge cases
│   ├── fuzz/
│   │   ├── PnlUtils.t.sol            # Fuzz PnL library
│   │   └── FundingRateManager.t.sol  # Fuzz funding rate bounds
│   └── mocks/
│       └── MockTaskManager.sol       # Drop-in CoFHE TaskManager for Foundry simulation
│
├── script/
│   └── DeployShadeSpot.s.sol         # Single script to deploy the pure FHE ecosystem
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

Every sensitive metric inside ShadeSpot is kept natively dark:

| Data | Encrypted type | When decrypted |
|---|---|---|
| Position size | `euint128` | At close / liquidation (to release vault reserves) |
| Collateral | `euint128` | At liquidation (to compute reward) |
| Entry price | `euint128` | Never — all PnL math runs purely in FHE |
| Direction (isLong) | `ebool` | Never |
| Trigger price (orders) | `euint128` | At order execution check |
| Can-liquidate flag | `ebool` | Single-bit decrypt gating the liquidation |
| Net settlement | `euint128` | Final amount sent to trader at close |
| Pool LP balance | `euint64` | Only when LP withdraws (encrypted ≥ check, one bit) |
| Pool totalLiquidity | `euint64` | Never exposed as plaintext |

### CoFHE settlement pattern (important)

On live CoFHE networks, decryption is asynchronous and some deployments enforce ACL checks even for FHE operations. ShadeSpot’s close and liquidation flows use a **request → off-chain decrypt-with-proof → finalize** pattern to avoid `ACLNotAllowed` and “decrypt not ready” deadlocks. See `docs/COFHE_DECRYPT_WITH_PROOF.md`.

---

## Core Operational Flow

### FHERouter — `trading/FHERouter.sol`
Entry-point for the platform. Accepts an FHERC20 token as collateral via `confidentialTransferFrom`. Users must call `fheToken.setOperator(address(fheRouter), untilTimestamp)` once before their first trade. This replaces the legacy `approve` logic to guarantee mempool privacy.

### PositionManager — `core/PositionManager.sol`
Owns the encrypted position lifecycle. All sensitive fields are stored as FHE ciphertexts. PnL and hourly funding fees are mathematically calculated directly against the ciphertext using `FHE.mul` / `FHE.div` / `FHE.select`. Only one actual value is decrypted per closure.

### FHEVault — `core/FHEVault.sol`
Holds the operational liquidity with fully encrypted internal accounting. `totalLiquidity`, `totalReserved`, and every specific user's `lpBalance` value are `euint64` ciphertexts. No on-chain observer or MEV Searcher can map pool depth or determine the wealth of LP providers.

### FHEFundingRateManager — `core/FHEFundingRateManager.sol`
Tracks long and short open interest globally as encrypted limits. Derives a continuously compounding funding rate via FHE without ever publishing actual Long vs Short dominance publicly. 

### LiquidationManager — `core/LiquidationManager.sol`
Entry-point for liquidator bots. Emits encrypted verification requests that are executed by the threshold nodes.

### FHEOrderManager — `trading/FHEOrderManager.sol`
Stores limit and trigger orders. Target parameters are persisted as `euint128`. Keeper networks natively monitor these by executing zero-knowledge boundary FHE comparisons against the Oracle.

---

## Tokens

### IEncryptedERC20 — `tokens/IEncryptedERC20.sol`
Interface that `FHERouter` and `FHEVault` use to interact with any FHERC20-compatible token wrapper (e.g. `eUSDC`). Uses `setOperator` and `confidentialTransferFrom` instead of standard allowances.

### MockFHEToken — `tokens/MockFHEToken.sol`
Extends Fhenix `FHERC20` base contracts for local testing environments. Balances are strictly `euint64` ciphertexts. Standard `transfer` / `transferFrom` / `approve` routines are intentionally bricked—use confidentiality routers only!

---

## Running Tests

The ShadeSpot test suite operates heavily against Mock Task Managers to rapidly simulate synchronous FHE mathematical bounds.

```bash
forge test                                     # all 56 pure FHE tests
forge test -v                                  # verbose output
forge test --match-path test/unit/FHEPool.t.sol # Specifically target the broad E2E integration
```

---

## Deployment (Pure FHE)

To deploy the ShadeSpot ecosystem exclusively on encrypted FHERC20 collaterals:

```bash
export PRIVATE_KEY=0x...
export INDEX_TOKEN=0x...          # ETH token address (used for oracle + position keys)

# COLLATERAL_TOKEN_FHE is optional
# If unset, MockFHEToken is deployed automatically
forge script script/DeployShadeSpot.s.sol --rpc-url <RPC_URL> --broadcast
```

To use real tokens on a live network (like Arbitrum Sepolia), pass the encrypted wrapper:

```bash
export COLLATERAL_TOKEN_FHE=0x...    # e.g., real eUSDC token wrap address
```

### Protocol Operator Setup (Users)

Before trading or providing liquidity, users **must** grant the protocol `Operator` status on their encrypted token wrapper. This replaces standard ERC-20 allowances:

```solidity
fheToken.setOperator(address(fheRouter), type(uint48).max);
```

---

## Build

```bash
forge build
```

`via_ir = true` is strictly required in `foundry.toml` to optimize stack depth and compile the FHE circuits efficiently.

## Deployments (Arb Sepolia)

  ```bash
  == Logs ==
  MockFHEToken deployed: 0xb3f5e35969E587e84c57519CC85459600D198f34
  
=== ShadeSpot FHE deployment complete ===
  FHE collateral:       0xb3f5e35969E587e84c57519CC85459600D198f34
  PriceOracle:          0xFedC9be2506F20df6e07bE1C90288660a011d203
  FHEFundingManager:    0xF8CFdeBAA82FDb0C710F25CAD06F6f672C267A87
  FHEVault:             0xAe20131B74b930c58A2536F11b3bddA899E7187c
  PositionManager:      0xA1b1D50830C3f630ceD11b4ffdbDa4aa6029615E
  FHEOrderManager:      0x3db1b90996baDb4fE804843EE16768861f750487
  LiquidationManager:   0xaf823b9A427B31cC9776F998cD58a3A2018FFabC
  FHERouter:            0xf30703A365777EE4c4751c5A025646D9AcF505E5
  
Index token (ETH):    0x980B62Da83eFf3D4576C647993b0c1D7faf17c73
```