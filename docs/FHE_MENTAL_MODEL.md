# FHE Mental Model (Shadespot implementation)

This document explains how **FHE-based operations** work in this repo, using the same primitives you see in the Solidity contracts (via `cofhe-contracts/FHE.sol`).

Official documentation reference: [Fhenix / CoFHE docs](https://cofhe-docs.fhenix.zone/).

---

## Core idea

- **Users encrypt inputs client-side** (SDK) and send ciphertexts to contracts.
- Contracts compute directly on ciphertexts (`euint64`, `euint128`, `ebool`) without seeing plaintext.
- When the protocol must **enforce** a rule derived from encrypted data (e.g. “liquidity is sufficient”), it uses a **two-phase pattern**:
  - **Phase 1**: compute an encrypted boolean, store/emit its **handle** (`bytes32`)
  - **Phase 2**: submit the **plaintext boolean + threshold signature**; the contract verifies/publishes it and then enforces with normal Solidity `require(...)`

---

## 1) Types and “handles”

### Encrypted calldata inputs: `InEuint64 / InEuint128 / InEbool`

These are encrypted inputs created off-chain and passed into contract functions.

In `FHERouter`, you convert them into runtime encrypted values:

- `euint64 eCollateral = FHE.asEuint64(encCollateral);`
- `euint128 eTriggerPrice = FHE.asEuint128(encTriggerPrice);`
- `ebool eIsLong = FHE.asEbool(encIsLong);`

### Runtime encrypted values: `euint64 / euint128 / ebool`

These are the opaque encrypted values that support FHE arithmetic and logic.

Examples in this repo:

- size: `eSize = FHE.mul(eCollateral, eLeverage)`
- comparisons: `FHE.gte(...)`, `FHE.lte(...)`
- branching without revealing data: `FHE.select(condition, a, b)`

### Handles: `bytes32` via `e*.unwrap(...)`

`euint64.unwrap(x)` / `ebool.unwrap(b)` returns a `bytes32` **ciphertext handle**.

Handles are used to:

- **emit events** so off-chain systems can request decrypt + proof generation
- **store correlation state** between phase 1 and phase 2
- **compare equality** to ensure phase-2 inputs match phase-1 inputs (anti-tampering)

You’ll see this pattern in:

- `FHERouter.pendingOpenRequests` storing handles for open-position parameters
- `FHEVault.ReserveLiquidityCheckSubmitted(...)` emitting `hasLiqHandle` and `sizeHandle`
- `FHEOrderManager.OrderPriceCheckSubmitted(...)` emitting `shouldExecHandle`

---

## 2) Permits / ciphertext access control: `FHE.allow` vs `FHE.allowTransient`

Encrypted values effectively have an **ACL**: you must grant permission for other addresses/contracts to operate on or decrypt/verify them.

### `FHE.allow(value, addr)`

Grants `addr` permission over a ciphertext beyond the current call context.

You use it to:

- allow downstream contracts to consume values (`vault`, `positionManager`, `orderManager`)
- allow users to later decrypt their own ciphertext outputs (`trader`)
- allow privileged roles to finalize proofs (`finalizer`, `liquidationManager`)

### `FHE.allowTransient(value, addr)`

Grants short-lived permission for intermediate computation flows (conceptually “temporary use”).

You use it where the contract needs to read multiple encrypted fields for calculations but doesn’t want to broadly grant long-lived permissions (e.g. close/liquidation computations in `PositionManager`).

---

## 3) Decrypt proofs: `verifyDecryptResult` vs `publishDecryptResult`

The protocol relies on a threshold network to provide decrypt results with signatures.

### `FHE.verifyDecryptResult(encValue, plain, sig)`

Use when you want to **validate** that `(plain, sig)` is a correct decrypt result for `encValue`.

Seen in:

- `FHEVault.confirmOpenLiquidityCheck(...)`
- `FHEVault.finalizeWithdrawalWithProof(...)`

Mental model: “Is this decrypt result authentic for that ciphertext handle?”

### `FHE.publishDecryptResult(encValue, plain, sig)`

Use when you want to **publish** the decrypt result on-chain (so subsequent logic can rely on it).

Seen in:

- `FHEOrderManager.executeOrder(...)`
- `PositionManager.finalizeClosePosition(...)`
- `PositionManager.finalizeLiquidation(...)`

Mental model: “Make this plaintext officially bound to that ciphertext, then enforce with normal Solidity checks.”

---

## 4) Why two-phase flows exist (and where they appear here)

### The rule: you can’t `require()` on encrypted booleans

You can compute an encrypted boolean like:

- `ebool hasLiqEnc = FHE.gte(eAvail, eSize);`

But Solidity `require(...)` needs a **plaintext** bool.

So the repo uses:

- **phase 1** to compute/store/emit an encrypted boolean handle
- **phase 2** to submit a plaintext decrypt + proof and then enforce

---

## 5) Two-phase flows in this repo (concrete mappings)

### A) Open position (liquidity gate)

**Phase 1 (router):** `FHERouter.submitOpenPositionCheck(...)`

- Converts encrypted inputs to `euint*` / `ebool`
- Computes encrypted size `eSize`
- Calls `FHEVault.submitReserveLiquidityCheck(trader, eSize)`
- Stores ciphertext handles in `pendingOpenRequests[trader]` for later matching

**Phase 2 (router):** `FHERouter.finalizeOpenPosition(..., hasLiqPlain, hasLiqSig)`

- Calls `FHEVault.storeReserveLiquidityProof(trader, hasLiqPlain, hasLiqSig)`
- Verifies ciphertext handles match the phase-1 request and clears it
- Pulls encrypted collateral into the vault via `confidentialTransferFrom`
- Opens position via `PositionManager.openPositionFHE(...)`

Inside `PositionManager.openPositionFHE`, the vault consumes the approval:

- `vault.reserveLiquidity(trader)` → requires vault’s `_liqApproved[trader] == true`

### B) Trigger/limit orders (price condition + liquidity gate)

**Phase 1:** `FHERouter.submitOrderExecutionChecks(orderId)`

- Submits vault liquidity check for encrypted size
- Submits order-manager price check using oracle price
- Returns two handles: `hasLiqHandle`, `shouldExecHandle`

**Phase 2:** `FHERouter.finalizeOrderExecution(...)`

- `FHEOrderManager.executeOrder(...)` publishes + enforces `shouldExecPlain`
- Vault stores liquidity proof via `storeReserveLiquidityProof(...)`
- Position is opened via `PositionManager.openPositionFHE(...)`

### C) LP withdrawal (balance + liquidity checks)

**Phase 1:** `FHERouter.submitLiquidityWithdrawalCheck(shares)` → `FHEVault.submitWithdrawalCheck(...)`

- Computes encrypted `hasBal` and `hasLiq`
- Emits handles in `WithdrawCheckSubmitted(...)`

**Phase 2:** `FHERouter.finalizeLiquidityWithdrawal(...)` → `FHEVault.finalizeWithdrawalWithProof(...)`

- Verifies decrypt proofs
- Transfers an encrypted amount to the LP

### D) Close / liquidation finalization

`PositionManager` emits encrypted handles in requests (close/liquidation), then a trusted role later submits decrypt proofs and publishes results to finalize settlement or liquidation.

---

## 6) Reading/writing FHE code: practical heuristics

- If a function must enforce a condition derived from encrypted data, expect a **two-phase split**.
- If an encrypted value is passed to another contract, you almost always need `FHE.allow(eValue, thatContract)`.
- If a user should be able to decrypt something later, you need `FHE.allow(eValue, user)`.
- `bytes32` handles are primarily for **off-chain correlation** (decrypt/proof workflows) and **integrity checks** (ensuring the same ciphertext is reused).

