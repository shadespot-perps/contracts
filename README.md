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

### CoFHE settlement pattern (important)

On live CoFHE networks, decryption is asynchronous and some deployments enforce ACL checks even for FHE operations. ShadeSpot’s close and liquidation flows use a **request → off-chain decrypt-with-proof → finalize** pattern to avoid `ACLNotAllowed` and “decrypt not ready” deadlocks. See `docs/COFHE_DECRYPT_WITH_PROOF.md`.

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

## Test Logs

``` bash

Ran 4 tests for test/unit/PnlUtils.t.sol:PnlUtilsTest
[PASS] test_CalculatePnL_Long_Loss() (gas: 2474)
[PASS] test_CalculatePnL_Long_Profit() (gas: 2147)
[PASS] test_CalculatePnL_Short_Profit() (gas: 1721)
[PASS] test_ZeroEntryPrice() (gas: 707)
Suite result: ok. 4 passed; 0 failed; 0 skipped; finished in 480.69µs (385.71µs CPU time)

Ran 13 tests for test/unit/Vault.t.sol:VaultTest
[PASS] test_Deposit() (gas: 63955)
[PASS] test_DepositRevert_OnlyRouter() (gas: 13958)
[PASS] test_DepositRevert_ZeroAmount() (gas: 14008)
[PASS] test_Initialization() (gas: 23276)
[PASS] test_PayTrader_OnlyCollateral() (gas: 147843)
[PASS] test_PayTrader_ProfitAndCollateral() (gas: 149854)
[PASS] test_ReceiveLoss() (gas: 66563)
[PASS] test_ReleaseLiquidity() (gas: 92795)
[PASS] test_ReserveLiquidity() (gas: 90142)
[PASS] test_ReserveLiquidity_Revert_InsufficientVaultLiquidity() (gas: 18111)
[PASS] test_Withdraw() (gas: 144988)
[PASS] test_WithdrawRevert_InsufficientBalance() (gas: 15665)
[PASS] test_WithdrawRevert_LiquidityLocked() (gas: 142343)
Suite result: ok. 13 passed; 0 failed; 0 skipped; finished in 3.30ms (1.40ms CPU time)

Ran 5 tests for test/unit/PositionManager.t.sol:PositionManagerTest
[PASS] test_CalculatePnL_Long() (gas: 113552)
[PASS] test_CalculatePnL_Short() (gas: 119616)
[PASS] test_ClosePosition_Profit() (gas: 361767)
[PASS] test_OpenPosition_HappyPath() (gas: 289626)
[PASS] test_OpenPosition_Revert_MaxLeverage() (gas: 18147)
Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 4.46ms (4.61ms CPU time)

Ran 8 tests for test/unit/FundingRateManager.t.sol:FundingRateManagerTest
[PASS] test_DecreaseOpenInterest() (gas: 47173)
[PASS] test_IncreaseOpenInterest() (gas: 42545)
[PASS] test_OI_Revert_OnlyPositionManager() (gas: 13017)
[PASS] test_UpdateFunding_CumulatesAcrossIntervals() (gas: 120939)
[PASS] test_UpdateFunding_LongDominant() (gas: 115892)
[PASS] test_UpdateFunding_NoOI_NoChange() (gas: 41188)
[PASS] test_UpdateFunding_ShortDominant() (gas: 116038)
[PASS] test_UpdateFunding_TooEarly_NoChange() (gas: 48615)
Suite result: ok. 8 passed; 0 failed; 0 skipped; finished in 4.49ms (982.08µs CPU time)

Ran 6 tests for test/unit/OrderManager.t.sol:OrderManagerTest
[PASS] test_CancelOrder() (gas: 188190)
[PASS] test_CancelOrder_Revert_NotOwner() (gas: 204912)
[PASS] test_CreateOrder() (gas: 205958)
[PASS] test_ExecuteOrder_Long() (gas: 254230)
[PASS] test_ExecuteOrder_Long_Revert_PriceNotReached() (gas: 262637)
[PASS] test_ExecuteOrder_Short() (gas: 234487)
Suite result: ok. 6 passed; 0 failed; 0 skipped; finished in 8.32ms (1.22ms CPU time)

Ran 4 tests for test/integration/UserFlow.t.sol:UserFlowTest
[PASS] test_Flow_AddRemoveLiquidity() (gas: 107620)
[PASS] test_Flow_Liquidation() (gas: 431390)
[PASS] test_Flow_OpenClose_Loss() (gas: 414916)
[PASS] test_Flow_OpenClose_Profit() (gas: 414860)
Suite result: ok. 4 passed; 0 failed; 0 skipped; finished in 8.37ms (5.34ms CPU time)

Ran 4 tests for test/unit/LiquidationManager.t.sol:LiquidationManagerTest
[PASS] test_Liquidate_PaysLiquidatorReward() (gas: 367979)
[PASS] test_Liquidate_RemovesPosition() (gas: 368838)
[PASS] test_Liquidate_Revert_NotLiquidatable() (gas: 410051)
[PASS] test_Liquidate_VaultAbsorbsLoss() (gas: 367739)
Suite result: ok. 4 passed; 0 failed; 0 skipped; finished in 8.37ms (6.18ms CPU time)

Ran 33 tests for test/unit/FHEPool.t.sol:FHEPoolTest
[PASS] test_FHERouter_AddLiquidity_VaultEncryptedLiquidityGrows() (gas: 142512)
[PASS] test_FHERouter_ClosePosition_Loss_TraderReceivesReducedPayout() (gas: 453336)
[PASS] test_FHERouter_ClosePosition_Loss_VaultTokenBalanceIncreases() (gas: 452657)
[PASS] test_FHERouter_ClosePosition_PositionDeleted() (gas: 453428)
[PASS] test_FHERouter_ClosePosition_Profit_TraderReceivesPayout() (gas: 452945)
[PASS] test_FHERouter_ClosePosition_Profit_VaultTokenBalanceDecreases() (gas: 453182)
[PASS] test_FHERouter_Liquidation_LiquidatorReceivesReward() (gas: 503449)
[PASS] test_FHERouter_Liquidation_NotLiquidatable_Reverts() (gas: 524111)
[PASS] test_FHERouter_Liquidation_PositionDeleted() (gas: 505416)
[PASS] test_FHERouter_OpenPosition_CollateralMovedToVault() (gas: 383103)
[PASS] test_FHERouter_OpenPosition_Long_PositionExists() (gas: 386491)
[PASS] test_FHERouter_OpenPosition_NoOperator_Reverts() (gas: 120608)
[PASS] test_FHERouter_OpenPosition_WrongToken_Reverts() (gas: 11838)
[PASS] test_FHERouter_RemoveLiquidity_Works() (gas: 161340)
[PASS] test_FHEToken_ConfidentialTransferFrom_NoOperator_Reverts() (gas: 103740)
[PASS] test_FHEToken_ConfidentialTransferFrom_WithOperator_Works() (gas: 172876)
[PASS] test_FHEToken_Mint_EncryptedBalanceCorrect() (gas: 90853)
[PASS] test_FHEToken_SetOperator_IsOperator_True() (gas: 37143)
[PASS] test_FHEToken_StandardApprove_Reverts() (gas: 9229)
[PASS] test_FHEToken_StandardTransferFrom_Reverts() (gas: 8983)
[PASS] test_FHEToken_StandardTransfer_Reverts() (gas: 9713)
[PASS] test_FHEVault_Deposit_EncryptedLiquidityUpdated() (gas: 11341)
[PASS] test_FHEVault_LPBalance_Encrypted() (gas: 14063)
[PASS] test_FHEVault_LPBalance_IsEncrypted() (gas: 13689)
[PASS] test_FHEVault_ReceiveLoss_EncryptedLiquidityIncreases() (gas: 29024)
[PASS] test_FHEVault_ReleaseLiquidity_EncryptedReservedDecreases() (gas: 55918)
[PASS] test_FHEVault_ReserveLiquidity_EncryptedReservedUpdated() (gas: 61965)
[PASS] test_FHEVault_ReserveLiquidity_Insufficient_Reverts() (gas: 33984)
[PASS] test_FHEVault_TotalLiquidity_IsEncrypted_NotPlaintext() (gas: 11803)
[PASS] test_FHEVault_Withdraw_InsufficientBalance_Reverts() (gas: 25901)
[PASS] test_FHEVault_Withdraw_LiquidityLocked_Reverts() (gas: 399215)
[PASS] test_FHEVault_Withdraw_ReducesEncryptedBalance() (gas: 160988)
[PASS] test_FHEVault_Withdraw_TransfersTokensToLP() (gas: 161376)
Suite result: ok. 33 passed; 0 failed; 0 skipped; finished in 8.43ms (32.68ms CPU time)

Ran 1 test for test/fuzz/PnlUtils.t.sol:PnlUtilsFuzzTest
[PASS] testFuzz_CalculatePnL(uint256,uint256,uint256,bool) (runs: 257, μ: 5237, ~: 5231)
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 19.73ms (19.28ms CPU time)

Ran 1 test for test/fuzz/FundingRateManager.t.sol:FundingRateManagerFuzzTest
[PASS] testFuzz_FundingRateCalculationLimits(uint256,uint256) (runs: 256, μ: 117525, ~: 118817)
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 30.95ms (30.59ms CPU time)

Ran 1 test for test/invariant/InvariantTest.t.sol:InvariantTest
[PASS] invariant_VaultSolvent() (runs: 256, calls: 128000, reverts: 0)

╭------------------+---------------+-------+---------+----------╮
| Contract         | Selector      | Calls | Reverts | Discards |
+===============================================================+
| InvariantHandler | closePosition | 42976 | 0       | 0        |
|------------------+---------------+-------+---------+----------|
| InvariantHandler | openPosition  | 42619 | 0       | 0        |
|------------------+---------------+-------+---------+----------|
| InvariantHandler | setPrice      | 42405 | 0       | 0        |
╰------------------+---------------+-------+---------+----------╯

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 26.51s (26.51s CPU time)

Ran 11 test suites in 26.51s (26.61s CPU time): 80 tests passed, 0 failed, 0 skipped (80 total tests)

```

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

## Deployment (Arbitrum Sepolia)

```bash

== Logs ==
  MockUSDC deployed:    0x3b450aA23141DB0F9d2fb5eF9d1763d0FE72f655
  MockFHEToken deployed: 0x2Efc2A6E950b711e18d387C6F9fd8091754b5eA0
  
=== ShadeSpot Dual-Pool deployment complete ===

  
--- Pool 1 (USDC / ETH) ---
  USDC collateral:      0x3b450aA23141DB0F9d2fb5eF9d1763d0FE72f655
  PriceOracle:          0x63403Ab53f1808f92a267D274A311d5d49803c42
  FundingRateManager:   0x5e1C2Ee18B317326D2dD2612A7b8820F053B7080
  Vault:                0xE4B3b5bff7CdA60c4472eA9FC59Ba512675e3BbC
  PositionManager:      0xb13fb9aD1Bb84C5943f2885e5fBd89218BE2f378
  OrderManager:         0x82f0f5B3dC827511986D4852074C70668Be4fbB2
  LiquidationManager:   0x17C597cFa193b46f820D3B7576F983222694d1c0
  Router:               0xd2AC4Ce57e5286839644e69dC68701be90e90D8f
  
--- Pool 2 (FHE Token / ETH) ---
  FHE collateral:       0x2Efc2A6E950b711e18d387C6F9fd8091754b5eA0
  PriceOracle:          0x9eFe93CD6170bE3457D75C1579F8218e22B0B28b
  FundingRateManager:   0x942Ef207e7601f53b00626CF9D9DEEAC058B8493
  FHEVault:             0x2e828d107cfCd552977BCca37aE48C668eE2bfB3
  PositionManager:      0x370c5Cd69371a94785A66E1d44cc9401e04A92E1
  OrderManager:         0xF6bDc069A2f373D28b0Fa82dC76bC5b8b1945741
  LiquidationManager:   0x5aC7c34aF0a87B113805181959d806Eb6673829D
  FHERouter:            0x35b9E1a2351764Efb713D48DFFE9DE1247E06f51
  
Index token (ETH):    0x980B62Da83eFf3D4576C647993b0c1D7faf17c73


```