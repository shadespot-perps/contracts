## CoFHE integration findings & recommended pattern

This note documents the production-chain issues we encountered while integrating CoFHE into ShadeSpot, why our initial settlement design was fragile, and the mitigation/review checklist for follow-up hardening.

---

## Background (what CoFHE actually enforces)

ShadeSpot uses CoFHE encrypted types via `lib/cofhe-contracts/contracts/FHE.sol`. CoFHE introduces two non-obvious constraints:

- **ACL (Access Control Layer) can apply to FHE ops, not just decrypts**  
  Some TaskManager deployments enforce that a caller must be explicitly allowed to operate on a ciphertext handle before performing FHE operations involving it (not only before decrypting it). In practice this means contracts must manage permissions for:
  - newly created ciphertext handles (persist allowance for later txs)
  - stored ciphertext handles loaded from storage (transient allowance in the current tx)

- **Decryption is asynchronous on live networks**  
  `FHE.getDecryptResultSafe(handle)` can legitimately return `(0, false)` until the off-chain CoFHE network fulfills the decrypt request. A contract must not rely on synchronous decrypt completion inside the same transaction.

Additionally, the CoFHE TaskManager used by this repo is a **pre-deployed external contract** with an address hardcoded in CoFHE’s `FHE.sol` (`TASK_MANAGER_ADDRESS`). ShadeSpot does not deploy or upgrade it.

---

## What was “lagging behind” in our original design

Our earlier on-chain settlement logic (close/liquidate) assumed patterns that work in local Foundry tests but fail on a live CoFHE network:

- **Synchronous decrypt assumption**  
  We were calling `getDecryptResultSafe(...)` and reverting if decrypt was not ready. On live networks, decrypt is typically not ready in the same tx.

- **“createDecryptTask then revert” is self-defeating**  
  When a function requests a decrypt task and then reverts, the `createDecryptTask(...)` call is reverted too. This prevents the decrypt request from ever being persisted on-chain, so decrypt can never become “ready”.

- **Missing / incomplete ACL allowance**  
  We were not consistently granting the `PositionManager` permission to perform FHE operations on:
  - ciphertexts created during `openPosition` (persist allowance needed for later txs)
  - ciphertexts stored in `positions[key]` (transient allowance needed per-tx)
  The symptom on Arbitrum Sepolia was `ACLNotAllowed` when trying to compute or decrypt during close/liquidation flows.

These issues only surfaced on a real network; Foundry’s `MockTaskManager` makes decrypt effectively synchronous and does not reflect live async behavior.

---

## The new design pattern: request → decrypt off-chain → finalize with proof

We migrated **close** and **liquidation** in `src/core/PositionManager.sol` to CoFHE’s recommended “decrypt-with-proof” model.

### 1) Request step (on-chain)

In the request tx, we:

- perform all computation in encrypted domain (PnL, funding, direction checks, etc.)
- compute the final ciphertext(s) that will be needed for settlement
- store handles in a `pending*` mapping for later finalization
- call `FHE.allowPublic(handle)` for the handle(s) that must be decryptable
- emit an event containing the handle(s)
- **return successfully** (no “decrypt not ready” revert)

Implemented as:

- `requestClosePosition(...)`  
  Stores `pendingFinalAmount[positionKey] = eFinalAmount` and allows public decrypt for:
  - `eFinalAmount`
  - `position.size` (used to release reserved liquidity)
  Emits `CloseRequested(positionKey, trader, token, isLong, finalAmountHandle)`.

- `liquidate(...)` (now request step; called by `LiquidationManager`)  
  Stores `pendingCanLiquidate[positionKey] = canLiquidateEnc` and allows public decrypt for:
  - `canLiquidateEnc` (single-bit gate)
  - `position.collateral` and `position.size` (needed for reward + reserve release)
  Emits `LiquidationRequested(...)`.

### 2) Off-chain decrypt-with-proof (client / keeper)

An off-chain actor (keeper, backend, user client) reads the handle(s) and executes:

- `@cofhe/sdk` → `decryptForTx(handle).withoutPermit().execute()`

For each handle this returns:

- `decryptedValue` (plaintext)
- `signature` (Threshold Network signature)

### 3) Finalize step (on-chain)

In the finalize tx, we take the plaintext + signature for each handle and call:

- `FHE.publishDecryptResult(handle, plaintext, signature)`

This verifies the Threshold Network proof on-chain and publishes the plaintext result for that handle, after which we proceed with settlement using the provided plaintext values.

Implemented as:

- `finalizeClosePosition(...)`  
  Publishes decrypt results for `pendingFinalAmount[key]` and `position.size`, then:
  - releases vault reserves for `sizePlain`
  - pays trader `finalAmount`
  - updates open interest and deletes the position

- `finalizeLiquidation(...)` (called by `LiquidationManager.finalizeLiquidation`)  
  Publishes decrypt results for:
  - `pendingCanLiquidate[key]` (must be `true`)
  - `position.collateral`, `position.size`
  then:
  - releases vault reserves
  - transfers liquidator reward and socializes remaining loss
  - updates open interest and deletes the position

---

## ACL handling we added (why it matters)

To prevent `ACLNotAllowed`, we apply the following rule in `PositionManager`:

- **Persist allowance for newly created ciphertexts that must be usable later**
  - In `openPosition(...)`, after creating `eCollateral`, `eLeverage`, `eSize`, `ePrice`, `eIsLong` we call:
    - `FHE.allow(handle, address(this))`

- **Transient allowance for stored ciphertexts when operating in a tx**
  - At the start of `requestClosePosition(...)` and `liquidate(...)`, we call:
    - `FHE.allowTransient(position.size, address(this))`, etc.

This explicitly grants the `PositionManager` the right to use ciphertext handles for FHE ops during the current tx and across subsequent txs.

---

## Why this pattern is safer

- **No reliance on “decrypt ready now”**: request tx never blocks; finalize tx carries proofs.
- **No rollback of decrypt requests**: request tx does not revert, so public decryptability + pending handle storage is durable.
- **Verifier-backed plaintext**: `publishDecryptResult` prevents an untrusted relayer from supplying arbitrary plaintext.
- **Works with relayers/keepers**: the user doesn’t need to run the decrypt client themselves if a keeper service does it.

---

## Reviewer checklist / mitigations (recommended next steps)

The migration solved the core live-network issues for close and liquidation, but reviewers should go deeper on the following.

### A) Migrate remaining “decrypt not ready” code paths

`src/core/FHEVault.sol` still uses a legacy pattern in:

- `withdraw`
- `reserveLiquidity`
- `releaseLiquidity`
- `payTrader`

These functions call `getDecryptResultSafe(...)`, then `createDecryptTask(...)`, then **revert("decrypt not ready")**. On live networks this risks permanently preventing decrypt progress because the task creation can be reverted along with the tx.

**Mitigation**: refactor these to the same request/finalize pattern:

- request functions should:
  - compute encrypted checks
  - `allowPublic(...)` on the gating bit / capped amount handle
  - persist handle(s) in storage (e.g., `pendingWithdraw[msg.sender]`, `pendingProfitCap[txId]`)
  - emit events with handles
  - return without revert
- finalize functions should:
  - accept plaintext + signature(s)
  - `publishDecryptResult(...)`
  - complete the transfer/accounting

### B) Add replay / double-finalize protection

Current `PositionManager` finalize functions clear pending mappings (`pendingFinalAmount[key] = 0`, etc.) and delete positions. That is good, but reviewers should ensure:

- **Finalize cannot be called twice** for the same request.
- **Finalize uses the correct request output** (handle is the one stored in `pending*`).
- **Finalize cannot be called before request** (already guarded by non-zero pending handle).

Optional mitigation: include a monotonically increasing `nonce` per position and include it in the `positionKey` or pending storage key, to make “one request per finalize” explicit and to support multiple sequential closes in future designs.

### C) Caller/role restrictions & MEV considerations

Finalize is currently permissionless (anyone can submit proofs). This is usually acceptable because proofs bind the plaintext to the handle, but reviewers should consider:

- whether a third-party finalizer can grief by finalizing at an inconvenient time (generally no, because it settles deterministically)
- whether liquidation finalization should be restricted to the requesting liquidator to avoid reward hijacking (currently the liquidator address is passed into finalize; make sure the caller cannot substitute themselves in a way that steals rewards)

Mitigation options:

- store `requestedBy` in the request step and require finalize sender matches it, or
- store and use the liquidator from request storage rather than trusting an input param at finalize

### D) Signature / chain binding correctness

Review assumptions about:

- **chainId binding**: ensure off-chain decrypt sets the correct chain id (e.g., `421614` for Arbitrum Sepolia).
- **handle formatting**: SDK expects `BigInt(handle)`; contracts expect correct `bytes32` wrapped custom type.

Mitigation: standardize a small off-chain “finalizer” script (per network) that:

- reads `CloseRequested/LiquidationRequested` events
- decrypts handles
- submits finalize tx with the correct parameters

### E) Liveness / timeouts / stuck requests

If the CoFHE network is unavailable, requests may not be finalizable.

Mitigations to consider:

- add a timeout after which a position can be force-closed via an alternate path (protocol-specific trade-off)
- add a “cancel request” pathway that clears pending handles (without changing position) so a new request can be issued
- keepers: run multiple decrypt providers / retries

### F) Event + storage indexing reliability

We emit handle(s) via events and also store them in `pending*` mappings. Reviewers should validate:

- events include enough indexed fields for off-chain consumers (`positionKey`, `trader`, `token`, `isLong`)
- storage getters are sufficient for clients that missed events

### G) Test realism gap

Foundry tests use `MockTaskManager` where decrypt is synchronous. That can hide async pitfalls.

Mitigation: add at least one integration test or script that:

- runs on a live CoFHE-enabled testnet
- demonstrates request → decryptForTx → finalize for both close and liquidation

---

## Minimal operational playbook (Arbitrum Sepolia)

- call request:
  - `Router.closePosition(...)` or `LiquidationManager.liquidate(...)` (request step)
- off-chain:
  - decrypt handle(s) from `CloseRequested/LiquidationRequested` (or `pending*` storage)
  - get `(plaintext, signature)` for each handle
- call finalize:
  - `PositionManager.finalizeClosePosition(...)` or `LiquidationManager.finalizeLiquidation(...)`

### PoC transactions (explorer links)

These are real Arbitrum Sepolia transactions from our recent end-to-end flow (open → request close → finalize close):

- **Open position**: `https://sepolia.arbiscan.io/tx/0x1f681ace45c1a1215d85ab81d70a0462c388aa81fd78dc2ab28f0ec656968c2d`
- **Request close**: `https://sepolia.arbiscan.io/tx/0x7ff9548d9f641bf5562565cf8fb627fd98bb493d6a2d26c8685ef9976462a073`
- **Finalize close (publishDecryptResult proofs)**: `https://sepolia.arbiscan.io/tx/0xb6c06e89dfffb02879d4d31d383fea208f4c6f7c5d0d0550a7a6528073323095`

