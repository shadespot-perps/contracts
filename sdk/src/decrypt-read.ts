/**
 * decrypt-read.ts
 *
 * Reads decryption results from the CoFHE TaskManager for a pending close.
 *
 * Flow:
 *   1. Derives the eFinalAmount ctHash from PositionManager.pendingFinalAmount
 *   2. Calls TaskManager.createDecryptTask() to explicitly kick the dispatcher
 *      (mirrors the two-phase pattern used in pool2-open — committed tx = event
 *       the dispatcher can see)
 *   3. Polls TaskManager.getDecryptResultSafe() until the dispatcher publishes
 *   4. Once available, prints the plaintext settlement amount and the
 *      arguments needed to call finalizeClosePosition
 */

import { Wallet, JsonRpcProvider, Contract } from "ethers";
import { RPC_URL, PRIVATE_KEY, TASK_MANAGER } from "./config";

const TASK_MANAGER_ABI = [
  "function getDecryptResultSafe(uint256 ctHash) external view returns (uint256 result, bool exists)",
  "function createDecryptTask(uint256 ctHash, address requestor) external",
  "function verifyDecryptResult(uint256 ctHash, uint256 result, bytes calldata signature) external view returns (bool)",
  "function decryptResultSigner() external view returns (address)",
  "event DecryptionResult(uint256 ctHash, uint256 result, address indexed requestor)",
];

const POSITION_MANAGER_ABI = [
  "function getPositionKey(address trader, address token, bool isLong) public pure returns (bytes32)",
  "function pendingFinalAmount(bytes32 positionKey) external view returns (bytes32)",
  "function positions(bytes32 key) external view returns (address owner, address indexToken, bytes32 size, bytes32 collateral, bytes32 entryPrice, int256 entryFundingRate, bytes32 isLong, bool exists)",
];

// ── Config ────────────────────────────────────────────────────────────────────

const IS_LONG           = true;
const POLL_INTERVAL_MS  = 5_000;   // 5 s between polls
const POLL_MAX_MS       = 300_000; // 5 min total

// ── Helpers ───────────────────────────────────────────────────────────────────

async function pollForResult(
  taskManager: Contract,
  ctHash: bigint,
): Promise<bigint> {
  const start = Date.now();
  let dots = 0;

  while (Date.now() - start < POLL_MAX_MS) {
    const [result, exists]: [bigint, boolean] =
      await taskManager.getDecryptResultSafe(ctHash);

    if (exists) {
      process.stdout.write("\n");
      return result;
    }

    if (dots % 12 === 0 && dots > 0) {
      // print elapsed every ~60 s
      process.stdout.write(` ${Math.round((Date.now() - start) / 1000)}s`);
    }
    process.stdout.write(".");
    dots++;
    await new Promise(r => setTimeout(r, POLL_INTERVAL_MS));
  }

  throw new Error(`Timed out after ${POLL_MAX_MS / 1000}s — dispatcher may not be active.`);
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const provider    = new JsonRpcProvider(RPC_URL);
  const wallet      = new Wallet(PRIVATE_KEY, provider);
  const taskManager = new Contract(TASK_MANAGER, TASK_MANAGER_ABI, wallet);

  const { POOL2 } = await import("./config");

  console.log("TaskManager:      ", TASK_MANAGER);
  console.log("Dispatcher signer:", await taskManager.decryptResultSigner());

  // ── 1. Derive ctHash from pendingFinalAmount ─────────────────────────────

  const pm  = new Contract(POOL2.POSITION_MANAGER, POSITION_MANAGER_ABI, wallet);
  const key = await pm.getPositionKey(
    wallet.address,
    process.env.INDEX_TOKEN!,
    IS_LONG,
  );

  const handle: string = await pm.pendingFinalAmount(key);
  if (BigInt(handle) === 0n) {
    console.log("\nNo pending close for this position.");
    console.log("Run `npm run pool2:close` first, then re-run `npm run decrypt:read`.");
    process.exit(0);
  }

  const ctHash = BigInt(handle);
  console.log("\nctHash (eFinalAmount):", handle);

  // ── 2. Check if already decrypted ────────────────────────────────────────

  {
    const [result, exists]: [bigint, boolean] =
      await taskManager.getDecryptResultSafe(ctHash);

    if (exists) {
      printResult(result, handle, POOL2);
      return;
    }
  }

  // ── 3. Kick the dispatcher with an explicit createDecryptTask tx ──────────
  // Same pattern as pool2:open — a committed tx means a TaskCreated event that
  // the CoFHE dispatcher can observe and act on, unlike the reverted txs from
  // the old inline getDecryptResultSafe loop.

  console.log("\nNot yet decrypted. Submitting explicit decrypt task to dispatcher...");
  try {
    const kickTx = await taskManager.createDecryptTask(ctHash, wallet.address);
    await kickTx.wait();
    console.log("createDecryptTask tx:", kickTx.hash);
  } catch (e: any) {
    // ACL may reject if the handle isn't allowed for this caller.
    // requestClosePosition calls FHE.allowPublic which sets the global allow flag;
    // if the ACL's isAllowed checks that flag the tx will succeed.
    console.warn("createDecryptTask failed (ACL may not allow public access):", e.shortMessage ?? e.message);
    console.log("Proceeding to poll anyway — dispatcher may still pick it up.");
  }

  // ── 4. Poll until result is published ────────────────────────────────────

  console.log(`\nPolling every ${POLL_INTERVAL_MS / 1000}s (max ${POLL_MAX_MS / 1000}s)...`);
  const result = await pollForResult(taskManager, ctHash);

  printResult(result, handle, POOL2);
}

function printResult(result: bigint, handle: string, _POOL2: unknown) {
  console.log("\n=== Decrypt result available ===");
  console.log("  eFinalAmount (raw):", result.toString());
  console.log("  in token units:   ", (Number(result) / 1e6).toFixed(6));
  console.log("\nTo finalize the close, call FHERouter (or PositionManager directly):");
  console.log("  finalizeClosePosition(trader, token, isLong, finalAmount, finalAmountSig, sizePlain, sizeSig)");
  console.log("  trader:      ", "your wallet address");
  console.log("  finalAmount: ", result.toString());
  console.log("  ctHash:      ", handle);
  console.log("\n(The dispatcher's signature for these values is in the DecryptionResult event)");
}

main().catch(console.error);
