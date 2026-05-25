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
| Plain ERC-20 users excluded from privacy | Router wraps plain tokens into FHE ciphertexts on-chain — position is indistinguishable from a fully encrypted open |
| LP ownership proportions observable on-chain | LP shares issued as `euint64` ciphertexts via `EncryptedLPToken`; pool ownership never exposed |

---

## Core Architecture

High-level relationships between traders/LPs, `FHERouter`, and core modules:

![General Architecture](diagrams/General%20Architecture.png)

Text overview (same structure as the diagram):

```
┌─────────────────────────────────────────────────────────────────────┐
│                        TRADER / LP                                  │
│                  (interacts via FHE-encrypted tx)                   │
└───────────────────────────┬─────────────────────────────────────────┘
                            │  setOperator once (replaces approve)
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        TRADER / LP                                  │
│         plain ERC-20 OR encrypted FHERC20 — both supported          │
└───────────────────────────┬─────────────────────────────────────────┘
                            │  setOperator once (replaces approve)
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        FHERouter.sol                                │
│           Primary entry-point — routes all user actions             │
│ openPosition │ openPositionPlain │ closePosition │ closePlainPayout │
│ addLiquidity │ addLiquidityPlain │ createOrder                      │
└──────┬──────────────┬────────────────┬──────────────────┬───────────┘
       │              │                │                  │
       ▼              ▼                ▼                  ▼
┌────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ FHEVault   │  │PositionManage│  |FHEOrderManag │  │FHEFunding    │
│            │  │r             │  │  er          │  │RateManager   │
│euint64     │  │euint128 size │  │euint128      │  │euint128      │
│totalLiq    │  │euint128 coll │  │triggerPrice  │  │eLongOI       │
│totalReserve│  │euint128 entry│  │euint64 coll  │  │eShortOI      │
│plainReserve│  │ebool isLong  │  │ebool isLong  │  │eCumFundRate  │
└─────┬──────┘  └──────┬───────┘  └──────────────┘  └──────────────┘
      │                │
      ▼         ┌──────┴────────┐
┌──────────────┐│              ▼
│EncryptedLP   ││   ┌──────────────┐   ┌──────────────┐
│Token (SLP)   ││   │PriceOracle   │   │Liquidation   │
│euint64 shares│││  │(public price)│   │Manager       │
│mint/burn/    │││  │              │   │(ebool canLiq)│
│transfer      │└─► └──────────────┘   └──────────────┘
└──────────────┘
```

### Opening a position (market order flow)

Encrypted inputs go through reserve/check phases, CoFHE decrypt for guards, then `FHERouter` opens the position against `PositionManager` and `FHEVault`:

![Open position — overview](diagrams/Open%20Position.png)

![Open position — continuation](diagrams/Open%20Position%202.png)

![Open position — continuation](diagrams/Open%20Position%203.png)

![Open position — continuation](diagrams/Open%20Position%204.png)

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

The liquidity pool uses encrypted accounting throughout. LPs cannot be targeted based on observable vault depth. LP shares are issued as `euint64` ciphertexts via `EncryptedLPToken` — pool ownership proportions are never computable by a third party.

```
  Vault Internal State:

  totalLiquidity       euint64  ████████████████  ← total pool size, hidden
  totalReserved        euint64  ████████████████  ← reserved for open positions, hidden
  plainUnderlyingReserve uint256  (public)        ← plain-payout capacity; no per-LP detail

  EncryptedLPToken (SLP) state:
  encryptedBalanceOf[addr] euint64  ████████████  ← per-LP shares, hidden
  encryptedTotalSupply     euint64  ████████████  ← total shares, hidden

  ┌──────────────────────────────────────────────────────────────────┐
  │  Deposit Flow — two paths, identical share output:               │
  │                                                                  │
  │  addLiquidity(eAmount)     FHERC20 euint64 → vault               │
  │  addLiquidityPlain(amount) plain ERC-20 → vault wraps to euint64 │
  │   └─ plainUnderlyingReserve += amount (funds plain-close payouts)│
  │                                                                  │
  │  Share issuance (fully encrypted):                               │
  │  eShares = FHE.div(FHE.mul(eAmount, eTotalSupply), eTotalLiq)    │
  │   lpToken.mint(lp, eShares)  ← Mint event emits bytes32 handle   │
  │                                no readable amount ever emitted   │
  │                                                                  │
  │  Withdraw Flow (2-phase):                                        │
  │  Phase 1: submitWithdrawalCheck → hasBal & hasLiq (ebool)        │
  │  Phase 2a: finalizeWithdrawalWithProof → confidentialTransfer    │
  │  Phase 2b: finalizeWithdrawalPlainWithProof → plain ERC-20       │
  │            drawn from plainUnderlyingReserve                     │
  └──────────────────────────────────────────────────────────────────┘

  Three-Phase Liquidity Reservation (on open):

  Phase 1 ─ submitOpenLiquidityCheck()
    hasLiq = FHE.gte(totalLiquidity − totalReserved, eRequiredSize)
    emit handle

  Phase 2 ─ confirmOpenLiquidityCheck()
    verify CoFHE proof, store encrypted approval

  Phase 3 ─ consumeOpenLiquidityApproval()
    consume approval, increment totalReserved (all encrypted)
    no plaintext size ever crosses a contract boundary
```

---

## Feature 9 — Composable Open and Close Paths

Every combination of plain ERC-20 and encrypted collateral is supported across open and close. All four paths produce identical `PositionManager` storage — an observer cannot tell which was used.

```
  Four supported paths:

  ┌────────────────────────────────────────────────────────────────────┐
  │ Path                    │ Open collateral   │ Close settlement     │
  ├────────────────────────────────────────────────────────────────────┤
  │ enc-open  / enc-close   │ FHERC20 euint64   │ encrypted euint64    │
  │ enc-open  / plain-close │ FHERC20 euint64   │ plain ERC-20         │
  │ plain-open / enc-close  │ plain ERC-20 →    │ encrypted euint64    │
  │                         │ wrapped on-chain  │                      │
  │ plain-open / plain-close│ plain ERC-20 →    │ plain ERC-20         │
  │                         │ wrapped on-chain  │                      │
  └────────────────────────────────────────────────────────────────────┘

  The critical invariant — plain-open is NOT a plain position:

  Phase A ─ submitOpenPositionCheckPlain(token, plainCollateral, encLev, encIsLong)
    ├─ underlyingToken.transferFrom(trader → vault)
    ├─ collateralToken.wrap(vault, amount)   ← plain ERC-20 encrypted on-chain
    ├─ FHE.asEuint64(amount) stored as eCollateral
    └─ vault.submitOpenLiquidityCheck()      emit handle for off-chain decrypt

  Phase B ─ finalizeOpenPositionPlain(token, hasLiqPlain, hasLiqSig)
    ├─ vault.confirmOpenLiquidityCheck()     verify CoFHE proof
    └─ pm.openPosition()                     stores size/coll/entry/isLong as FHE ciphertexts

  From Phase B onward: position is indistinguishable from any encrypted-open.
  Observer sees only bytes32 ciphertext handles in PositionManager storage.

  Plain-close settlement draws from plainUnderlyingReserve, accumulated by:
    - plain-open collateral  (recordPlainDeposit at open)
    - plain LP deposits      (addLiquidityPlain)
  Any position — regardless of how it was opened — can close to plain ERC-20.
  If reserve is exhausted, finalizeClosePlainPayout reverts; position left intact.

  Router entry points:
  ┌─────────────────────────────────────────────────────────────────┐
  │ submitDecryptTaskForOpen → openPosition          encrypted open │
  │ submitOpenPositionCheckPlain → finalizeOpenPositionPlain        │
  │                                                    plain open   │
  │ requestClosePosition → finalizeClosePosition    encrypted close │
  │ requestClosePlainPayout → finalizeClosePlainPayout  plain close │
  │ requestCloseEncryptedPayout → finalizeCloseEncryptedPayout      │
  │                                plain-open → encrypted payout    │
  └─────────────────────────────────────────────────────────────────┘
```

---

## Feature 10 — Encrypted LP Token (SLP)

`EncryptedLPToken` (name: "Shadespot LP Token", symbol: "SLP") extends FHE privacy to the LP layer. Anyone providing liquidity to ShadeSpot now has a position as private as any trade being made against it.

```
  LP Token Properties:

  encryptedBalanceOf[addr]  euint64  ████████████  ← never plaintext
  encryptedTotalSupply      euint64  ████████████  ← never plaintext
  Mint event  → emits bytes32 handle only (no readable amount)
  Burn event  → emits bytes32 handle only

  Share issuance — fully encrypted arithmetic:
  eShares = FHE.div(FHE.mul(eAmount, encryptedTotalSupply), totalLiquidity)
  Only the vault may call mint() or burn().

  Two deposit paths — same private share output:
  ┌────────────────────────────────────────────────────────────────┐
  │ addLiquidity(eAmount)     FHERC20 euint64 → encrypted shares   │
  │ addLiquidityPlain(amount) plain ERC-20 → wrapped → enc shares  │
  │                           also builds plainUnderlyingReserve   │
  └────────────────────────────────────────────────────────────────┘

  Withdrawal (two-phase CoFHE pattern):

  Phase 1 ─ submitWithdrawalCheck(lp, shares)
    hasBal  = FHE.gte(lpBalance[lp], eShares)          encrypted check
    eAmount = (eShares × totalLiquidity) / totalSupply  encrypted arithmetic
    hasLiq  = FHE.gte(eAvail, eAmount)                  encrypted check
    emit WithdrawCheckSubmitted(hasBalHandle, hasLiqHandle, amountHandle)

  Phase 2a ─ finalizeWithdrawalWithProof (encrypted payout)
    verify proofs → lpToken.burn(lp, eShares) → confidentialTransfer(lp, eAmount)

  Phase 2b ─ finalizeWithdrawalPlainWithProof (plain ERC-20 payout)
    verify proofs + amountSig → lpToken.burn → unwrap → underlyingToken.transfer(lp)

  Peer-to-peer share transfer (two-phase, amount never revealed):

  Phase 1 ─ submitTransfer(to, eAmount)
    hasBal = FHE.gte(encryptedBalanceOf[msg.sender], eAmount)
    emit TransferSubmitted(from, to, hasBalHandle, amountHandle)

  Phase 2 ─ finalizeTransfer(balPlain, balSig)
    verify proof → encryptedBalanceOf[from] -= eAmount
                 → encryptedBalanceOf[to]   += eAmount
    emit Transfer(from, to, amountHandle)   ← bytes32 handle only
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
| Net settlement (encrypted close) | `euint128` | Final payout at close | Trader + vault |
| Net settlement (plain close) | plain `uint256` | At `finalizeClosePlainPayout` | Visible on-chain |
| Which open/close path used | — | **Never** — all paths produce identical ciphertext state | Nobody |
| LP share balance | `euint64` | Only via Threshold Network permit by holder | LP only |
| LP pool ownership proportion | — | **Never** — total supply also encrypted | Nobody |
| LP withdrawal amount (encrypted) | `euint64` | At withdrawal (holder only) | LP only |
| LP withdrawal amount (plain) | plain `uint256` | At `finalizeWithdrawalPlainWithProof` | Visible on-chain |
| Total liquidity | `euint64` | **Never** as plaintext | Nobody |
| Total reserved | `euint64` | **Never** as plaintext | Nobody |
| `plainUnderlyingReserve` | plain `uint256` | Always public | Anyone — aggregate only, no per-LP detail |

---

## Full Operational Flow

```
  OPEN POSITION — encrypted collateral
  ─────────────────────────────────────
  Trader ──[setOperator once]──► FHERouter
                  1. submitDecryptTaskForOpen()
                     ├─ compute hasLiq check (encrypted)
                     └─ emit handle for off-chain decrypt
                  off-chain: decrypt(handle) → (canOpen, proof)
                  2. openPosition(proof)
                     ├─ verify proof on-chain
                     ├─ confidentialTransferFrom(trader → vault)
                     ├─ store encrypted position (size/coll/entry/isLong)
                     ├─ vault.reserveLiquidity()
                     └─ fundingManager.updateOI()

  OPEN POSITION — plain ERC-20 collateral
  ─────────────────────────────────────────
  Trader ──► FHERouter.submitOpenPositionCheckPlain(token, amount, encLev, encIsLong)
                  ├─ underlyingToken.transferFrom(trader → vault)
                  ├─ collateralToken.wrap(vault, amount)   ← encrypted on-chain
                  ├─ FHE.asEuint64(amount) stored as eCollateral
                  └─ vault.submitOpenLiquidityCheck()      emit handle
          off-chain: decrypt(handle) → (hasLiq, sig)
  Trader ──► FHERouter.finalizeOpenPositionPlain(token, hasLiqPlain, sig)
                  ├─ vault.confirmOpenLiquidityCheck()
                  └─ pm.openPosition()  ← all fields FHE ciphertexts; identical to enc-open

  CLOSE POSITION — encrypted payout
  ───────────────────────────────────
  Trader ──► FHERouter.requestClosePosition(posId)
                  ├─ compute ePnL, eFundingFee, eNetPnL (all FHE)
                  └─ emit RequestClose event (handle)
          off-chain: decrypt(handle) → (amount, sig)
  Keeper ──► FHERouter.finalizeClosePosition(posId, amount, sig, ...)
                  ├─ FHE.publishDecryptResult() — verify proof
                  ├─ vault.releaseLiquidity(size)
                  └─ token.confidentialTransfer(trader, amount)

  CLOSE POSITION — plain ERC-20 payout
  ──────────────────────────────────────
  Trader ──► FHERouter.requestClosePlainPayout(posId)
                  └─ sets plainPayoutRequested flag
  Keeper ──► FHERouter.finalizeClosePlainPayout(posId, finalAmount, sigs...)
                  ├─ verify CoFHE proofs for amount/size/collateral
                  ├─ vault.payTraderPlain() — draws from plainUnderlyingReserve
                  │    burns encrypted from vault, transfers plain ERC-20 to trader
                  └─ position deleted; plainPayoutRequested cleared

  LIQUIDATION
  ───────────
  Liquidator ──► LiquidationManager.liquidate(posKey)
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
│   │   ├── FHEVault.sol              # Encrypted euint64 LP accounting; plainUnderlyingReserve
│   │   ├── PositionManager.sol       # Position lifecycle; all fields encrypted
│   │   ├── FHEFundingRateManager.sol # Encrypted OI and hourly funding
│   │   └── LiquidationManager.sol    # Liquidation entry-point; single-bit FHE check
│   ├── trading/
│   │   ├── FHERouter.sol             # Primary user entry-point; plain + encrypted paths
│   │   └── FHEOrderManager.sol       # Encrypted limit / trigger orders
│   ├── oracle/
│   │   └── PriceOracle.sol           # Price feed (setPrice / getPrice)
│   ├── tokens/
│   │   ├── IEncryptedERC20.sol       # FHERC20 interface (operator model)
│   │   ├── IEncryptedLPToken.sol     # LP token interface (mint/burn)
│   │   ├── EncryptedLPToken.sol      # euint64 LP shares; two-phase transfer
│   │   └── MockFHEToken.sol          # FHERC20 token for testing
│   └── libraries/
│       └── PnlUtils.sol              # PnL helper library
│
├── test/
│   ├── unit/
│   │   ├── FHEPool.t.sol             # End-to-end FHE integration tests
│   │   ├── PlainCollateral.t.sol     # Plain-open position tests
│   │   ├── PlainPayoutClose.t.sol    # All four open/close path combinations
│   │   ├── PlainLPDeposit.t.sol      # Plain LP deposit / plain withdrawal tests
│   │   └── PnlUtils.t.sol            # Library edge cases
│   ├── fuzz/
│   │   ├── PnlUtils.t.sol            # Fuzz PnL library
│   │   └── FundingRateManager.t.sol  # Fuzz funding rate bounds
│   └── mocks/
│       └── MockTaskManager.sol       # CoFHE TaskManager for Foundry simulation
│
├── sdk/
│   └── src/
│       ├── flow-enc-open-plain-close.ts   # Encrypted open → plain ERC-20 close
│       ├── flow-plain-open-enc-close.ts   # Plain open → encrypted payout close
│       └── flow-plain-open-plain-close.ts # Plain open → plain ERC-20 close
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
forge test                                                  # full suite
forge test -v                                               # verbose output
forge test --match-path test/unit/FHEPool.t.sol            # E2E encrypted flow
forge test --match-path test/unit/PlainCollateral.t.sol    # plain-open tests
forge test --match-path test/unit/PlainPayoutClose.t.sol   # all four open/close paths
forge test --match-path test/unit/PlainLPDeposit.t.sol     # plain LP deposit/withdraw
forge test --match-path test/fuzz/                         # fuzz suite only
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
1.  PriceOracle
2.  FHEFundingRateManager
3.  FHEVault(collateralToken)
4.  EncryptedLPToken(vault)
5.  PositionManager(vault, oracle)
6.  FHEOrderManager(oracle, fundingManager)
7.  LiquidationManager(positionManager, fundingManager)
8.  FHERouter(positionManager, vault, orderManager, fundingManager, token, indexToken, underlyingToken)
9.  Wire: setRouter / setPositionManager / setLPToken / setUnderlyingToken / initializeToken
```

**Protocol Operator Setup (users must do this once):**

```solidity
// Encrypted collateral path
fheToken.setOperator(address(fheRouter), type(uint48).max);

// Plain collateral path — approve router to pull underlying ERC-20
underlyingToken.approve(address(fheRouter), amount);
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

== Logs ==
  MockFHEToken deployed: 0xDFF61c2e5fFB08bdfEd3520a37c86A2c976e3283
  
=== ShadeSpot FHE deployment complete ===
  FHE collateral:       0xDFF61c2e5fFB08bdfEd3520a37c86A2c976e3283
  PriceOracle:          0x5557D65E67124bA5b3ea3dAE17e9B473006bCd4E
  FHEFundingManager:    0xa5e08198e0E6268413D398b908Afe303b4aB4623
  FHEVault:             0x96D1Cc159775457EE7c03FF98683959F10FCc91C
  PositionManager:      0xa9147bc8274a87FC63c8BEa1dBBF07c62cd557F1
  FHEOrderManager:      0x81cA357f55b6C4763f2f5E1f11308D8e09457FA0
  LiquidationManager:   0x921c6e48F5a698BaC282aB6B022aa124dFF225c6
  FHERouter:            0x2Df347fd32cED9CD019C752E999f9ABf6E4613e4
  Finalizer:            0x2b284c179a65709fC823711e6D76134E55a63798
  
Index token (ETH):    0x980B62Da83eFf3D4576C647993b0c1D7faf17c73
```

cd shadespot && source .env && forge script script/DeployShadeSpot.s.sol:DeployShadeSpot \
  --rpc-url arbitrum_sepolia \
  --broadcast \
  --verify \
  --etherscan-api-key "$ARBISCAN_API_KEY" \
  -vvv