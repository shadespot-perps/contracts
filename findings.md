# ShadeSpot Findings

Bug reports, accounting discrepancies, and protocol observations logged during testing and review.

---

## [F-01] LP `totalLiquidity` not updated on trader profit/loss settlement

**Severity:** Medium  
**File:** `src/core/Vault.sol`, `src/core/PositionManager.sol`  
**Discovered:** E2E testing (Pool 1, USDC/ETH)

**Description:**  
`finalizeClosePosition` always calls `vault.payTrader(trader, 0, finalAmount)` with `profit=0`, regardless of whether the trader made a gain or loss. Inside `payTrader`, `totalLiquidity` is only decremented when `profit > 0`. As a result, LP capital is silently drained on profitable trades and LP earnings from losing trades are never accrued.

**Observed on-chain:**  
Trader opened 100 USDC 2x long at $3000, closed at $3300. `finalAmount = 120 USDC` was paid out but `totalLiquidity` remained `1000 USDC` instead of dropping to `980 USDC`.

**Fix:**  
Split `finalAmount` into `collateral` and `profitOrLoss` before calling the vault, and call `vault.receiveLoss()` when `finalAmount < collateral`.

---
