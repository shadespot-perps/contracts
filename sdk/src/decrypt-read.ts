/**
 * decrypt-read.ts
 *
 * Reads decryption results from the CoFHE TaskManager.
 *
 * On live CoFHE (Arbitrum Sepolia), when closePosition emits a PositionClosed
 * event containing a `settlementHandle` (bytes32 ctHash), the CoFHE dispatcher
 * asynchronously calls TaskManager.publishDecryptResult(ctHash, result, sig).
 *
 * This script:
 *   1. Polls TaskManager.getDecryptResultSafe(ctHash) until ready
 *   2. Optionally verifies the signature against the dispatcher's signing key
 */

import { Wallet, JsonRpcProvider, Contract, ethers } from "ethers";
import { RPC_URL, PRIVATE_KEY, TASK_MANAGER, ENC_TYPE } from "./config";
import { computeDecryptResultHash } from "./encrypt";

const TASK_MANAGER_ABI = [
  // Returns (result, exists) — exists=false if not yet decrypted
  "function getDecryptResultSafe(bytes32 ctHash) external view returns (uint256 result, bool exists)",

  // Verify without storing — returns true if signature is valid
  "function verifyDecryptResult(bytes32 ctHash, uint256 result, bytes calldata signature) external view returns (bool)",

  // Dispatcher signer address
  "function decryptResultSigner() external view returns (address)",

  // Events
  "event DecryptionResult(bytes32 indexed ctHash, uint256 result)",
];

/**
 * Poll until the CoFHE dispatcher has published the decrypt result.
 * Returns the plaintext result.
 */
async function waitForDecrypt(
  taskManager: Contract,
  ctHash: bigint,
  pollIntervalMs = 3000,
  maxWaitMs      = 120_000
): Promise<bigint> {
  const ctHashHex = ethers.zeroPadValue(ethers.toBeHex(ctHash), 32);
  const start     = Date.now();

  console.log("Polling for decrypt result of ctHash:", ctHashHex);

  while (Date.now() - start < maxWaitMs) {
    const [result, exists]: [bigint, boolean] =
      await taskManager.getDecryptResultSafe(ctHashHex);

    if (exists) {
      console.log("Decrypted result:", result.toString());
      return result;
    }

    process.stdout.write(".");
    await new Promise(r => setTimeout(r, pollIntervalMs));
  }

  throw new Error("Timed out waiting for CoFHE decrypt result");
}

/**
 * Listen for DecryptionResult events from TaskManager in real-time.
 * Resolves once the matching ctHash appears.
 */
async function listenForDecrypt(
  taskManager: Contract,
  ctHash: bigint,
  timeoutMs = 120_000
): Promise<bigint> {
  const ctHashHex = ethers.zeroPadValue(ethers.toBeHex(ctHash), 32);
  console.log("Listening for DecryptionResult event for ctHash:", ctHashHex);

  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      taskManager.off("DecryptionResult");
      reject(new Error("Timed out waiting for DecryptionResult event"));
    }, timeoutMs);

    taskManager.on("DecryptionResult", (emittedCtHash: string, result: bigint) => {
      if (emittedCtHash.toLowerCase() === ctHashHex.toLowerCase()) {
        clearTimeout(timer);
        taskManager.off("DecryptionResult");
        console.log("\nDecryptionResult event received:");
        console.log("  ctHash:", emittedCtHash);
        console.log("  result:", result.toString());
        resolve(result);
      }
    });
  });
}

// ── Demo — read a specific ctHash from a past close tx ───────────────────────

async function main() {
  const provider    = new JsonRpcProvider(RPC_URL);
  const wallet      = new Wallet(PRIVATE_KEY, provider);
  const taskManager = new Contract(TASK_MANAGER, TASK_MANAGER_ABI, wallet);

  // Replace with the settlementHandle bytes32 from a PositionClosed event
  // (emitted by PositionManager during closePosition)
  const SETTLEMENT_CT_HASH_HEX =
    "0xf6b4ad9088010621fa026fc62508534ea24cde9f143584667697a71c8eae0600";

  console.log("TaskManager:", TASK_MANAGER);
  console.log("Dispatcher signer:", await taskManager.decryptResultSigner());

  const ctHashBig = BigInt(SETTLEMENT_CT_HASH_HEX);

  // Try to read immediately (may already be available for the tx we ran above)
  const [result, exists]: [bigint, boolean] =
    await taskManager.getDecryptResultSafe(SETTLEMENT_CT_HASH_HEX);

  if (exists) {
    console.log("\nDecrypt result already available:");
    console.log("  net settlement (raw):", result.toString());
    console.log("  in USDC (6 dec):     ", (Number(result) / 1e6).toFixed(6));
  } else {
    console.log("\nNot yet decrypted. Starting live listener...");
    // Uncomment to wait for async decryption:
    // const liveResult = await listenForDecrypt(taskManager, ctHashBig);
    // console.log("Settlement:", liveResult.toString());

    // Or poll:
    // const polledResult = await waitForDecrypt(taskManager, ctHashBig);
    // console.log("Settlement:", polledResult.toString());
    console.log("(use waitForDecrypt() or listenForDecrypt() to await it)");
  }

  // ── Verify signature integrity ─────────────────────────────────────────────
  // If you have the dispatcher's signature bytes you can verify without re-calling:
  //
  // const chainId  = (await provider.getNetwork()).chainId;
  // const msgHash  = computeDecryptResultHash(result, ENC_TYPE.EUINT128, chainId, ctHashBig);
  // const recovered = ethers.recoverAddress(msgHash, signatureBytes);
  // console.log("Recovered signer:", recovered);
}

main().catch(console.error);
