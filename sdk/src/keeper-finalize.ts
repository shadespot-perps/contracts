/**
 * keeper-finalize.ts — CoFHE Settlement Keeper
 *
 * Completes the two-phase close-position flow for Pool 1 (USDC) and Pool 2 (FHE Token).
 *
 * Flow:
 *   1. Watches PositionManager for CloseRequested events (or targets a specific trader)
 *   2. For each pending close, calls @cofhe/sdk decryptForTx on both handles:
 *        - finalAmountHandle  (euint128 — net payout to trader)
 *        - sizeHandle         (euint128 — position size for OI accounting)
 *      The SDK contacts the Threshold Network directly and returns
 *      { decryptedValue: bigint, signature: string } — no on-chain event scanning needed.
 *   3. Calls PositionManager.finalizeClosePosition with the proven plaintexts + TN signatures.
 *
 * Uses .withoutPermit() because FHE.allowPublic() in requestClosePosition marks both
 * handles as globally accessible in the ACL (any address can decrypt them).
 *
 * Usage:
 *   POOL=1 npm run keeper                       # watch Pool 1 (default)
 *   POOL=2 npm run keeper:pool2                 # watch Pool 2
 *   POOL=1 TRADER=0xABC npm run keeper          # one-shot for a specific trader
 *   FROM_BLOCK=12345678 POOL=1 npm run keeper   # replay + watch from a specific block
 */

import { ethers, Wallet, JsonRpcProvider, Contract, EventLog } from "ethers";
import { createCofheConfig, createCofheClient } from "@cofhe/sdk/node";
import { Ethers6Adapter } from "@cofhe/sdk/adapters";
import { arbSepolia } from "@cofhe/sdk/chains";
import { RPC_URL, PRIVATE_KEY, POOL1, POOL2 } from "./config";

// ── ABIs ─────────────────────────────────────────────────────────────────────

const POSITION_MANAGER_ABI = [
  "function finalizeClosePosition(bytes32 positionKey,uint256 finalAmount,bytes finalAmountSignature,uint256 sizePlain,bytes sizeSignature,uint256 collateralPlain,bytes collateralSignature,bool isLongPlain) external",
  "event CloseRequested(bytes32 indexed positionKey, address indexed trader, bytes32 finalAmountHandle, bytes32 sizeHandle)",
  "event CloseFinalized(bytes32 indexed positionKey, address indexed trader, bytes32 finalAmountHandle)",
  "event PositionOpened(bytes32 indexed positionKey, address indexed trader, bytes32 sizeHandle, bytes32 collateralHandle, bytes32 isLongHandle)",
];

// ── Config ────────────────────────────────────────────────────────────────────

const POOL            = parseInt(process.env.POOL ?? "1");
const SPECIFIC_TRADER = process.env.TRADER?.toLowerCase();
const FROM_BLOCK      = parseInt(process.env.FROM_BLOCK ?? "0");

// Retry decryptForTx — TN may need a moment after new CloseRequested
const DECRYPT_RETRIES     = 10;
const DECRYPT_RETRY_MS    = 15_000; // 15s between retries

// ── Types ─────────────────────────────────────────────────────────────────────

interface PendingClose {
  trader:            string;
  positionKey:       string;
  finalAmountHandle: bigint;
  sizeHandle:        bigint;
  collateralHandle:  bigint;
}

// ── decryptForTx with retry ───────────────────────────────────────────────────

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function decryptHandle(cofheClient: any, ctHash: bigint, label: string): Promise<{ value: bigint; sig: string }> {
  const ctHashHex = "0x" + ctHash.toString(16).padStart(64, "0");
  const permit = await cofheClient.permits.getOrCreateSelfPermit();

  for (let attempt = 1; attempt <= DECRYPT_RETRIES; attempt++) {
    try {
      console.log(`  [${label}] decryptForTx attempt ${attempt}/${DECRYPT_RETRIES}...`);
      const result = await cofheClient
        .decryptForTx(ctHashHex)
        .withPermit(permit)
        .execute();

      console.log(`  [${label}] decrypted: ${result.decryptedValue}`);
      return { value: result.decryptedValue as bigint, sig: result.signature as string };

    } catch (err: any) {
      const msg = err?.message ?? err?.code ?? String(err);
      console.warn(`  [${label}] attempt ${attempt} failed: ${msg}`);

      if (attempt === DECRYPT_RETRIES) {
        throw new Error(`decryptForTx [${label}] failed after ${DECRYPT_RETRIES} attempts: ${msg}`);
      }

      console.log(`  [${label}] retrying in ${DECRYPT_RETRY_MS / 1000}s...`);
      await new Promise(r => setTimeout(r, DECRYPT_RETRY_MS));
    }
  }

  // unreachable
  throw new Error(`decryptHandle unreachable`);
}

// ── Finalize ──────────────────────────────────────────────────────────────────

// Serializes finalizeClosePosition sends so concurrent decryptions don't race on nonce.
let txQueue = Promise.resolve();
function enqueueFinalize(fn: () => Promise<void>): void {
  txQueue = txQueue.then(fn).catch(() => {});
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function finalize(pending: PendingClose, pm: Contract, cofheClient: any): Promise<void> {
  const { trader, positionKey, finalAmountHandle, sizeHandle, collateralHandle } = pending;

  console.log(`\n[Finalize] trader=${trader}`);
  console.log(`  positionKey:        ${positionKey}`);
  console.log(`  finalAmountHandle:  0x${finalAmountHandle.toString(16).padStart(64, "0")}`);
  console.log(`  sizeHandle:         0x${sizeHandle.toString(16).padStart(64, "0")}`);
  console.log(`  collateralHandle:   0x${collateralHandle.toString(16).padStart(64, "0")}`);
  console.log(`  Requesting decryption from Threshold Network...`);

  // Decrypt all close-finalization handles concurrently.
  const [finalAmountRes, sizeRes, collateralRes] = await Promise.all([
    decryptHandle(cofheClient, finalAmountHandle, "finalAmount"),
    decryptHandle(cofheClient, sizeHandle,        "size"),
    decryptHandle(cofheClient, collateralHandle,  "collateral"),
  ]);

  console.log(`\n  finalAmount : ${finalAmountRes.value}  (${(Number(finalAmountRes.value) / 1e6).toFixed(6)} units)`);
  console.log(`  sizePlain   : ${sizeRes.value}`);
  console.log(`  collateral  : ${collateralRes.value}`);

  // Enqueue the send so concurrent decryptions don't race on the wallet nonce.
  await new Promise<void>((resolve, reject) => {
    enqueueFinalize(async () => {
      try {
        console.log(`\n  Calling finalizeClosePosition for ${trader}...`);
        const tx      = await pm.finalizeClosePosition(
          positionKey,
          finalAmountRes.value,
          finalAmountRes.sig,
          sizeRes.value,
          sizeRes.sig,
          collateralRes.value,
          collateralRes.sig,
          false,
        );
        const receipt = await tx.wait();

        console.log(`  tx:       ${tx.hash}`);
        console.log(`  block:    ${receipt?.blockNumber}  gas: ${receipt?.gasUsed}`);

        const iface = new ethers.Interface(POSITION_MANAGER_ABI);
        for (const log of receipt?.logs ?? []) {
          try {
            const parsed = iface.parseLog({ topics: [...log.topics], data: log.data });
            if (parsed?.name === "CloseFinalized") {
              console.log(`\n  CloseFinalized:`);
              console.log(`    positionKey : ${parsed.args.positionKey}`);
              console.log(`    trader      : ${parsed.args.trader}`);
              console.log(`    handle      : ${parsed.args.finalAmountHandle}`);
            }
          } catch {}
        }
        resolve();
      } catch (err) {
        reject(err);
      }
    });
  });
}

// ── Helper ────────────────────────────────────────────────────────────────────

async function resolveCollateralHandle(
  pm: Contract,
  positionKey: string,
  fromBlock: number,
): Promise<bigint | null> {
  const openedLogs = await pm.queryFilter(
    pm.filters.PositionOpened(positionKey, null),
    fromBlock,
    "latest",
  );
  if (openedLogs.length === 0) return null;
  const opened = openedLogs[openedLogs.length - 1] as EventLog;
  const collateralHandle = opened.args[3] as string;
  return BigInt(collateralHandle);
}

async function buildPendingFromEvent(
  pm: Contract,
  e: EventLog,
  fromBlock: number,
): Promise<PendingClose | null> {
  const positionKey = e.args[0] as string;
  const trader = e.args[1] as string;
  const finalAmountHandle = BigInt(e.args[2] as string);
  const sizeHandle = BigInt(e.args[3] as string);
  if (finalAmountHandle === 0n || sizeHandle === 0n) return null;

  const collateralHandle = await resolveCollateralHandle(pm, positionKey, fromBlock);
  if (!collateralHandle || collateralHandle === 0n) {
    console.warn(`  [Skip] collateral handle not found for position ${positionKey}`);
    return null;
  }

  return {
    trader,
    positionKey,
    finalAmountHandle,
    sizeHandle,
    collateralHandle,
  };
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const provider = new JsonRpcProvider(RPC_URL);
  const wallet   = new Wallet(PRIVATE_KEY, provider);

  const poolConfig = POOL === 2 ? POOL2 : POOL1;
  const PM_ADDR    = (poolConfig as { POSITION_MANAGER: string }).POSITION_MANAGER;

  console.log(`ShadeSpot Settlement Keeper — Pool ${POOL}`);
  console.log(`Wallet:          ${wallet.address}`);
  console.log(`PositionManager: ${PM_ADDR}`);
  console.log(`FROM_BLOCK:      ${FROM_BLOCK || "earliest"}`);

  // ── CoFHE client setup ────────────────────────────────────────────────────
  console.log(`\nConnecting @cofhe/sdk...`);
  const config = createCofheConfig({ supportedChains: [arbSepolia] });
  const cofheClient = createCofheClient(config);
  const { publicClient, walletClient } = await Ethers6Adapter(provider, wallet);
  await cofheClient.connect(publicClient, walletClient);
  console.log(`CoFHE client connected  chainId=${cofheClient.chainId}  account=${cofheClient.account}`);

  // ── Ethers contract ───────────────────────────────────────────────────────
  const pm = new Contract(PM_ADDR, POSITION_MANAGER_ABI, wallet);

  // Track active finalizations by finalAmountHandle to prevent duplicate work
  const inFlight = new Set<bigint>();

  function tryFinalize(pending: PendingClose): void {
    if (inFlight.has(pending.finalAmountHandle)) return;
    inFlight.add(pending.finalAmountHandle);

    finalize(pending, pm, cofheClient)
      .catch(err => console.error(`  Error finalizing:`, err.message ?? err))
      .finally(() => inFlight.delete(pending.finalAmountHandle));
  }

  // ── One-shot mode ─────────────────────────────────────────────────────────
  if (SPECIFIC_TRADER) {
    console.log(`\nOne-shot mode — trader: ${SPECIFIC_TRADER}`);
    const startBlock = FROM_BLOCK || 0;
    const reqLogs = await pm.queryFilter(
      pm.filters.CloseRequested(null, SPECIFIC_TRADER),
      startBlock,
      "latest",
    );

    let found = 0;
    for (const evt of reqLogs) {
      const pending = await buildPendingFromEvent(pm, evt as EventLog, startBlock);
      if (!pending) continue;
      found++;
      await finalize(pending, pm, cofheClient);
    }

    if (found === 0) {
      console.log(`No pending close for ${SPECIFIC_TRADER} on Pool ${POOL}.`);
      console.log(`Call closePosition first (emits CloseRequested).`);
    }
    return;
  }

  // ── Watch mode ────────────────────────────────────────────────────────────
  console.log(`\nWatch mode — listening for CloseRequested events... (Ctrl+C to stop)`);

  // Replay past CloseRequested events still pending — deduplicated by finalAmountHandle
  const startBlock = FROM_BLOCK || 0;
  console.log(`\nReplaying CloseRequested events since block ${startBlock || "earliest"}...`);

  const past = await pm.queryFilter(pm.filters.CloseRequested(), startBlock, "latest");
  const uniquePending = new Map<string, PendingClose>();

  for (const evt of past) {
    const pending = await buildPendingFromEvent(pm, evt as EventLog, startBlock);
    if (!pending) continue;
    uniquePending.set(pending.positionKey, pending);
  }

  let replayed = 0;
  for (const pending of uniquePending.values()) {
    replayed++;
    console.log(`  [Replay] trader=${pending.trader}  positionKey=${pending.positionKey}`);
    tryFinalize(pending);
  }
  console.log(`  Replayed ${replayed} unique pending close(s).\n`);

  // Live listener
  pm.on(
    "CloseRequested",
    async (
      positionKey:       string,
      trader:            string,
      finalAmountHandle: string,
      sizeHandle:        string,
      event:             EventLog,
    ) => {
      console.log(`\n[Event] CloseRequested  block=${event.blockNumber}  trader=${trader}  positionKey=${positionKey}`);
      const collateralHandle = await resolveCollateralHandle(pm, positionKey, Number(event.blockNumber));
      if (!collateralHandle || collateralHandle === 0n) {
        console.warn(`  [Skip] collateral handle not found for live event position ${positionKey}`);
        return;
      }
      tryFinalize({
        trader,
        positionKey,
        finalAmountHandle: BigInt(finalAmountHandle),
        sizeHandle: BigInt(sizeHandle),
        collateralHandle,
      });
    },
  );

  process.stdin.resume();
}

main().catch(console.error);
