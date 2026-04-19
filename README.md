# ShadeSpot — 100% FHE-Encrypted Perpetuals Protocol

ShadeSpot is a perpetual futures DEX built entirely on **Fully Homomorphic Encryption (CoFHE)**. Every trade parameter — size, collateral, entry price, direction — is stored and computed as an on-chain ciphertext. No observer, MEV bot, or liquidator ever sees plaintext position data.

PnL, funding fees, cross-position balances, and liquidation checks are computed entirely in the encrypted domain. Only the final settlement payout and a single liquidation boolean are ever decrypted — and only at the exact moment they are finalized.

---

## Why ShadeSpot?

| Problem (Legacy Perps) | ShadeSpot Solution |
|---|---|
| Positions visible in mempool → frontrun on open/close | All parameters encrypted before broadcast |
| Liquidation thresholds are public → bots hunt positions | Liquidation check is a single-bit decrypt; size/collateral remain hidden |
| LP pool depth exposed → adversarial liquidity timing | `totalLiquidity` and `totalReserved` are `euint64` — never plaintext |
| Order prices visible → order books are frontrunnable | Trigger prices stored as `euint128` ciphertexts; keeper compares in FHE |
| Funding rate reveals long/short dominance | Open interest tracked encrypted; rate derived without exposing OI |

---

## Core Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        TRADER / LP                                  │
│                  (interacts via FHE-encrypted tx)                   │
└───────────────────────────┬─────────────────────────────────────────┘
                            │  setOperator once (replaces approve)
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        FHERouter.sol                                │
│           Primary entry-point — routes all user actions             │
│   openPosition │ closePosition │ addLiquidity │ createOrder         │
└──────┬──────────────┬────────────────┬──────────────────┬───────────┘
       │              │                │                  │
       ▼              ▼                ▼                  ▼
┌────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ FHEVault   │  │PositionManager│ |FHEOrderManag │  │FHEFunding    │
│            │  │              │  │  er          │  │RateManager   │
│euint64     │  │euint128 size │  │euint128      │  │euint128      │
│totalLiq    │  │euint128 coll │  │triggerPrice  │  │eLongOI       │
│totalReserve│  │euint128 entry│  │euint64 coll  │  │eShortOI      │
│lpBalances  │  │ebool isLong  │  │ebool isLong  │  │eCumFundRate  │
└────────────┘  └──────┬───────┘  └──────────────┘  └──────────────┘
                       │
              ┌────────┴────────┐
              ▼                 ▼
    ┌──────────────┐   ┌──────────────┐
    │PriceOracle   │   │Liquidation   │
    │(public price)│   │Manager       │
    │              │   │(ebool canLiq)│
    └──────────────┘   └──────────────┘
```

---

## What is Fully Homomorphic Encryption (FHE)?

FHE allows computation directly on ciphertexts — the result, when decrypted, equals what you would get if you had computed on the plaintexts. ShadeSpot uses **CoFHE** (Threshold FHE) where decryption requires a distributed threshold network.

```
  Traditional Contract:                 ShadeSpot (FHE):

  store size = 1000  ← visible      store eSize = 0xab3f...c2  ← opaque
  store entry = 1800 ← visible      store eEntry = 0x77da...11  ← opaque
  pnl = (price-entry)*size           ePnL = FHE.mul(
         ← anyone can compute               FHE.sub(ePrice, eEntry),
                                             eSize)  ← computed in ciphertext
  result leaked in state             result stays encrypted until finalize
```

**Supported FHE Types in ShadeSpot:**

| Type | Bit Width | Used For |
|---|---|---|
| `euint64` | 64-bit | LP balances, liquidity totals, order collateral |
| `euint128` | 128-bit | Position size, collateral, entry price, PnL |
| `ebool` | 1-bit | Direction (isLong), liquidation flag, comparisons |

---

## Feature 1 — Complete Position Privacy

Every field of every position is an FHE ciphertext. Nothing about a live position leaks to the public chain state.

```
Position Struct (on-chain storage):

  ┌──────────────────────────────────────────────┐
  │ positionKey = keccak256(trader, token, nonce)│  ← direction NOT in key
  ├──────────────────────────────────────────────┤
  │  size        euint128  ████████████████████  │  always encrypted
  │  collateral  euint128  ████████████████████  │  always encrypted
  │  entryPrice  euint128  ████████████████████  │  never decrypted
  │  entryFund   euint128  ████████████████████  │  never decrypted
  │  isLong      ebool     █                     │  never decrypted
  └──────────────────────────────────────────────┘

  What an on-chain observer sees:
  mapping(bytes32 → Position) positions;
  → bytes32 key  (reveals: trader address + token + nonce, NOT direction)
  → 5 × bytes32 ciphertext handles (all opaque)
```

**Nonce-based keys** prevent position enumeration by direction — an adversary cannot determine if a trader is long or short even from the storage key.

---

## Feature 2 — Privacy-Preserving PnL Computation

All profit-and-loss math runs inside the FHE domain using `FHE.mul`, `FHE.div`, `FHE.sub`, and `FHE.select`. No intermediate value is ever exposed.

```
PnL Calculation Flow (all encrypted):

  ePrice (public oracle price, trivially encrypted)
  eEntry (stored ciphertext, never seen plaintext)

  eLongProfit  = FHE.mul(FHE.sub(ePrice, eEntry), eSize) / eEntry
  eShortProfit = FHE.mul(FHE.sub(eEntry, ePrice), eSize) / eEntry

  ePnL = FHE.select(position.isLong, eLongProfit, eShortProfit)
       └─── direction never revealed; result is an encrypted magnitude

  eFundingFee  = FHE.mul(eSize, FHE.sub(eCurrRate, eEntryRate)) / PREC
  eNetPnL      = FHE.sub(ePnL, eFundingFee)

                                ▼ only this is decrypted at finalize
                         plaintext settlement amount
```

---

## Feature 3 — Two-Phase Close / Liquidation (Async Decrypt Pattern)

Because CoFHE decryption is asynchronous (handled by a threshold network), ShadeSpot uses a **request → off-chain decrypt → finalize with proof** pattern for every value that must eventually be known.

```
  Phase 1: Request (on-chain)
  ─────────────────────────────────────────────
  trader calls requestClosePositionFHE()
        │
        ├─ compute ePnL, eFundingFee, eNetPnL in FHE
        ├─ store pending handles in mapping
        ├─ call FHE.allowPublic(handle)  ← threshold network can now decrypt
        └─ emit RequestClose(posKey, settlementHandle, sizeHandle)

  Phase 2: Off-chain Decrypt (keeper / user client)
  ─────────────────────────────────────────────
  off-chain reads handle from event
        │
        └─ cofhe-sdk.decryptForTx(handle).withoutPermit().execute()
               → returns (plaintext_amount, threshold_signature)

  Phase 3: Finalize (on-chain)
  ─────────────────────────────────────────────
  caller calls finalizeClosePosition(posKey, settlementAmount, sig)
        │
        ├─ FHE.publishDecryptResult(handle, settlementAmount, sig)
        │       └─ on-chain cryptographic verification of the proof
        ├─ vault.releaseLiquidity(plaintext_size)
        └─ token.confidentialTransfer(trader, settlementAmount)
```

This pattern guarantees liveness (no "decrypt not ready" reverts) and correctness (threshold signature proves the plaintext).

---

## Feature 4 — Encrypted Liquidation with a Single-Bit Reveal

Liquidators cannot calculate a position's distance-to-liquidation because they cannot see size, collateral, or entry price. Only a single `ebool` is decrypted to authorize liquidation.

```
  Liquidation Eligibility Check (all in FHE):

  isAtLoss = FHE.select(
               position.isLong,
               FHE.lt(eCurrentPrice, eEntryPrice),   ← long underwater
               FHE.gt(eCurrentPrice, eEntryPrice)    ← short underwater
             )

  eLoss      = FHE.mul(FHE.sub(eEntry, ePrice), eSize) / eEntry
  eThreshold = FHE.div(FHE.mul(eCollateral, 80), 100)   ← 80% loss threshold

  eCanLiq  = FHE.and(isAtLoss, FHE.gte(eLoss, eThreshold))
             └───────────────────────────────────────────────┘
                             │
                        ONLY THIS ebool is decrypted
                        (single bit: yes/no)
                             │
                   if true → finalizeLiquidation
                     ├─ liquidator reward: 5% of collateral
                     └─ remainder absorbed by vault

  Observer learns: "this position was liquidated"
  Observer does NOT learn: size, collateral, entry price, direction, loss amount
```

---

## Feature 5 — Encrypted Funding Rate

Funding rates on traditional perps reveal which side is dominant (long or short). ShadeSpot tracks open interest and computes funding entirely in the encrypted domain.

```
  Global Encrypted State (per token):

  eLongOI   euint128  ████████████████████  ← total long exposure, hidden
  eShortOI  euint128  ████████████████████  ← total short exposure, hidden

  Hourly Update (fully encrypted):

  eLongDom   = FHE.gte(eLongOI, eShortOI)          ← which side leads?
  eTotalOI   = FHE.add(eLongOI, eShortOI)
  eImbalance = FHE.select(eLongDom,
                 FHE.sub(eLongOI, eShortOI),         ← long excess
                 FHE.sub(eShortOI, eLongOI))         ← short excess
  eRate      = FHE.div(eImbalance, eTotalOI)

  eCumRate   = FHE.select(eLongDom,
                 FHE.add(eCumRate, eRate),            ← longs pay shorts
                 FHE.sub(eCumRate, eRate))            ← shorts pay longs

  ┌──────────────────────────────────────────────────────────────────┐
  │  Nobody can observe whether longs or shorts dominate.            │
  │  A trader's funding fee at close is computed as:                 │
  │  eFee = eSize × (eCumRate_now − eCumRate_entry) / PRECISION      │
  │  All encrypted, net result revealed only at position close.      │
  └──────────────────────────────────────────────────────────────────┘
```

---

## Feature 6 — Encrypted Limit & Trigger Orders

Order parameters — including trigger price, collateral, leverage, and direction — are stored as FHE ciphertexts. Keepers execute via encrypted comparisons; they never learn order details.

```
  Order Storage:

  ┌──────────────────────────────────────────────┐
  │  collateral   euint64   ████████████████████ │
  │  leverage     euint64   ████████████████████ │
  │  triggerPrice euint128  ████████████████████ │
  │  isLong       ebool     █                    │
  └──────────────────────────────────────────────┘

  Keeper Execution Flow:

  keeper calls submitDecryptTaskForOrder(orderId)
       │
       ├─ ePriceOk  = FHE.select(isLong,
       │                FHE.lte(eCurrentPrice, eTriggerPrice),  ← buy below trigger
       │                FHE.gte(eCurrentPrice, eTriggerPrice))  ← sell above trigger
       ├─ eLiqOk    = FHE.gte(eAvailableLiq, eRequiredSize)
       └─ emit handles for off-chain decrypt
              │
       off-chain decrypt → (priceOk: bool, liqOk: bool, proofs)
              │
       executeOrder(orderId, priceOk, liqOk, proofs)
              └─ if both true → openPosition with encrypted collateral
```

---

## Feature 7 — Encrypted LP Vault

The liquidity pool uses encrypted accounting throughout. LPs cannot be targeted based on observable vault depth.

```
  Vault Internal State:

  totalLiquidity  euint64  ████████████████  ← total pool size, hidden
  totalReserved   euint64  ████████████████  ← reserved for open positions, hidden
  lpBalance[addr] euint64  ████████████████  ← per-LP share, hidden

  ┌──────────────────────────────────────────────────────────────────┐
  │  Deposit Flow (encrypted share minting):                         │
  │  eShares = (eAmount × eTotalSupply) / eTotalLiquidity            │
  │  No LP ERC-20 token; shares stored as encrypted euint64          │
  │                                                                  │
  │  Withdraw Flow (2-phase):                                        │
  │  1. submitWithdrawCheck → compute hasBal & hasLiq (ebool)        │
  │  2. off-chain decrypt → (canWithdraw, proof)                     │
  │  3. withdrawWithProof  → verify proof, transfer encrypted amount │
  └──────────────────────────────────────────────────────────────────┘

  Three-Phase Liquidity Reservation (on open):

  Phase 1 ─ submitReserveLiquidityCheck()
    hasLiq = FHE.gte(totalLiquidity − totalReserved, eRequiredSize)
    emit handle

  Phase 2 ─ storeReserveLiquidityProof()
    verify CoFHE proof, store encrypted approval

  Phase 3 ─ reserveLiquidity()
    consume approval, increment totalReserved (all encrypted)
    no plaintext size ever crosses a contract boundary
```

---

## Feature 8 — FHERC20 Operator Model

ShadeSpot replaces ERC-20 `approve` with a time-bounded **operator** grant. This eliminates allowance visibility in mempool and state.

```
  Legacy ERC-20:                        FHERC20 Operator Model:

  approve(spender, amount)  ← public    setOperator(router, expiry)
  transferFrom(from, to, amount)        confidentialTransferFrom(from, to,
  → amount visible in event               eAmount, inputProof)
  → balance visible in state            → amount is euint64, never plaintext
                                        → balance is euint64, never plaintext

  User setup (once before first trade):
  fheToken.setOperator(address(fheRouter), type(uint48).max);
```

---

## FHE Privacy Model — Full Table

| Data | Encrypted Type | Decrypted When | Who Learns |
|---|---|---|---|
| Position size | `euint128` | At close/liquidation (to release vault) | Only the protocol flow |
| Collateral | `euint128` | At liquidation (to compute reward) | Only the protocol flow |
| Entry price | `euint128` | **Never** — PnL runs in FHE | Nobody |
| Direction (isLong) | `ebool` | **Never** | Nobody |
| Funding entry rate | `euint128` | **Never** | Nobody |
| Trigger price (orders) | `euint128` | At execution (encrypted comparison) | Nobody |
| Liquidation flag | `ebool` | Single-bit decrypt to gate liquidation | Yes/No only |
| Net settlement | `euint128` | Final payout at close | Trader + vault |
| LP balance | `euint64` | Only on LP withdrawal (one-bit check) | LP only |
| Total liquidity | `euint64` | **Never** as plaintext | Nobody |
| Total reserved | `euint64` | **Never** as plaintext | Nobody |

---

## Full Operational Flow

```
  OPEN POSITION
  ─────────────
  Trader ──[setOperator once]──► FHERouter
                                     │
                  1. submitDecryptTaskForOpen()
                     ├─ compute hasLiq check (encrypted)
                     └─ emit handle for off-chain decrypt
                                     │
                  off-chain: decrypt(handle) → (canOpen, proof)
                                     │
                  2. openPosition(proof)
                     ├─ verify proof on-chain
                     ├─ confidentialTransferFrom(trader → vault)
                     ├─ store encrypted position (size/coll/entry/isLong)
                     ├─ vault.reserveLiquidity()
                     └─ fundingManager.updateOI()

  CLOSE POSITION
  ──────────────
  Trader ──► FHERouter.requestClosePositionFHE()
                  │
                  ├─ compute ePnL, eFundingFee, eNetPnL (all FHE)
                  ├─ FHE.allowPublic(settlementHandle)
                  └─ emit RequestClose event

          off-chain: decrypt(settlementHandle) → (amount, sig)

  Keeper/Trader ──► FHERouter.finalizeClosePosition(amount, sig)
                  ├─ FHE.publishDecryptResult() — verify proof
                  ├─ vault.releaseLiquidity(size)
                  └─ token.confidentialTransfer(trader, amount)

  LIQUIDATION
  ───────────
  Liquidator ──► LiquidationManager.liquidate(posKey)
                  │
                  ├─ compute eCanLiquidate (single ebool, FHE)
                  ├─ FHE.allowPublic(canLiqHandle)
                  └─ emit LiquidationRequest event

          off-chain: decrypt(canLiqHandle) → (true/false, sig)

  Liquidator ──► LiquidationManager.finalizeLiquidation(posKey, true, sig)
                  ├─ verify proof
                  ├─ liquidator reward: 5% of collateral (encrypted transfer)
                  └─ vault absorbs remaining loss
```

---

## Repository Layout

```
contracts/
├── src/
│   ├── core/
│   │   ├── IVault.sol                # Vault routing interface
│   │   ├── FHEVault.sol              # Encrypted euint64 LP accounting
│   │   ├── PositionManager.sol       # Position lifecycle; all fields encrypted
│   │   ├── FHEFundingRateManager.sol # Encrypted OI and hourly funding
│   │   └── LiquidationManager.sol    # Liquidation entry-point; single-bit FHE check
│   ├── trading/
│   │   ├── FHERouter.sol             # Primary user entry-point
│   │   └── FHEOrderManager.sol       # Encrypted limit / trigger orders
│   ├── oracle/
│   │   └── PriceOracle.sol           # Price feed (setPrice / getPrice)
│   ├── tokens/
│   │   ├── IEncryptedERC20.sol       # FHERC20 interface (operator model)
│   │   └── MockFHEToken.sol          # FHERC20 token for testing
│   └── libraries/
│       └── PnlUtils.sol              # PnL helper library
│
├── test/
│   ├── unit/
│   │   ├── FHEPool.t.sol             # 56 end-to-end FHE integration tests
│   │   └── PnlUtils.t.sol            # Library edge cases
│   ├── fuzz/
│   │   ├── PnlUtils.t.sol            # Fuzz PnL library
│   │   └── FundingRateManager.t.sol  # Fuzz funding rate bounds
│   └── mocks/
│       └── MockTaskManager.sol       # CoFHE TaskManager for Foundry simulation
│
├── script/
│   └── DeployShadeSpot.s.sol         # Single-script full ecosystem deployment
│
└── lib/
    ├── cofhe-contracts/              # CoFHE library (euint128, ebool, FHE.*)
    ├── fhenix-confidential-contracts/# Fhenix FHERC20 base (euint64 balances)
    ├── forge-std/
    └── openzeppelin-contracts/
```

---

## Running Tests

```bash
forge test                                          # all 56 pure FHE tests
forge test -v                                       # verbose output
forge test --match-path test/unit/FHEPool.t.sol    # E2E integration only
forge test --match-path test/fuzz/                 # fuzz suite only
```

Tests use `MockTaskManager` to simulate synchronous FHE decryption in Foundry — no live CoFHE network needed for local testing.

---

## Deployment

```bash
export PRIVATE_KEY=0x...
export INDEX_TOKEN=0x...          # ETH token address (oracle + position keys)

# COLLATERAL_TOKEN_FHE is optional — MockFHEToken deployed if unset
forge script script/DeployShadeSpot.s.sol --rpc-url <RPC_URL> --broadcast
```

**Deployment order** (handled automatically by deploy script):

```
1. PriceOracle
2. FHEFundingRateManager
3. FHEVault(collateralToken)
4. PositionManager(vault, oracle)
5. FHEOrderManager(oracle, fundingManager)
6. LiquidationManager(positionManager, fundingManager)
7. FHERouter(positionManager, vault, orderManager, fundingManager, token, indexToken)
8. Wire: setRouter / setPositionManager / initializeToken
```

**Protocol Operator Setup (users must do this once):**

```solidity
fheToken.setOperator(address(fheRouter), type(uint48).max);
```

---

## Build

```bash
forge build
```

`via_ir = true` is required in `foundry.toml` to optimize stack depth and compile FHE circuits.

---

## Deployments (Arbitrum Sepolia)

```
MockFHEToken:       0xb3f5e35969E587e84c57519CC85459600D198f34
PriceOracle:        0xFedC9be2506F20df6e07bE1C90288660a011d203
FHEFundingManager:  0xF8CFdeBAA82FDb0C710F25CAD06F6f672C267A87
FHEVault:           0xAe20131B74b930c58A2536F11b3bddA899E7187c
PositionManager:    0xA1b1D50830C3f630ceD11b4ffdbDa4aa6029615E
FHEOrderManager:    0x3db1b90996baDb4fE804843EE16768861f750487
LiquidationManager: 0xaf823b9A427B31cC9776F998cD58a3A2018FFabC
FHERouter:          0xf30703A365777EE4c4751c5A025646D9AcF505E5
Index token (ETH):  0x980B62Da83eFf3D4576C647993b0c1D7faf17c73
```
