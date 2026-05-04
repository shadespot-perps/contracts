/**
 * close-listener.ts — Minimal "close finalizer" listener (Pool 2)
 *
 * Listens to PositionManager.CloseRequested and immediately finalizes:
 *  - finds collateralHandle from PositionOpened (fast backward search)
 *  - decrypts finalAmount/size/collateral via CoFHE Threshold Network
 *  - calls PositionManager.finalizeClosePosition (must be `finalizer`)
 *
 * Usage:
 *   npm run close-listener
 *
 * Optional env:
 *   FROM_BLOCK=263545000   # earliest block to search for PositionOpened
 *   REPLAY=1              # replay pending CloseRequested since FROM_BLOCK on startup
 *   POOL=2                # reserved (this script is Pool 2 only)
 */

import { ethers, Wallet, JsonRpcProvider, Contract, EventLog, TransactionReceipt } from "ethers";
import { createCofheConfig, createCofheClient } from "@cofhe/sdk/node";
import { Ethers6Adapter } from "@cofhe/sdk/adapters";
import { arbSepolia } from "@cofhe/sdk/chains";
import { RPC_URL, PRIVATE_KEY, POOL2 } from "./config";

const POSITION_MANAGER_ABI = [
  "function finalizeClosePosition(bytes32 positionKey,uint256 finalAmount,bytes finalAmountSignature,uint256 sizePlain,bytes sizeSignature,uint256 collateralPlain,bytes collateralSignature,bool isLongPlain) external",
  "function getMyPosition(bytes32 key) view returns (tuple(address owner,address indexToken,bytes32 size,bytes32 collateral,bytes32 entryPrice,bytes32 entryFundingRateBiased,bytes32 eLeverage,bytes32 isLong,bool exists,uint256 leverage))",
  "event CloseRequested(bytes32 indexed positionKey, address indexed trader, bytes32 finalAmountHandle, bytes32 sizeHandle)",
  "event CloseFinalized(bytes32 indexed positionKey, address indexed trader, bytes32 finalAmountHandle)",
  "event PositionOpened(bytes32 indexed positionKey, address indexed trader, bytes32 sizeHandle, bytes32 collateralHandle, bytes32 isLongHandle)",
] as const;

const FROM_BLOCK = parseInt(process.env.FROM_BLOCK ?? "0");
const REPLAY = process.env.REPLAY === "1";

const OPEN_LOOKBACK_WINDOW = 200_000; // blocks per step
const OPEN_LOOKBACK_STEPS = 40; // 8M blocks max search

const DECRYPT_RETRIES = 15;
const DECRYPT_RETRY_MS = 10_000;

const POLL_INTERVAL_MS = parseInt(process.env.POLL_INTERVAL_MS ?? "2000");
const LOG_CHUNK_SIZE = parseInt(process.env.LOG_CHUNK_SIZE ?? "2000");
const RPC_RETRIES = parseInt(process.env.RPC_RETRIES ?? "8");
// Avoid large `eth_getLogs` requests that trigger Infura limits.
const MAX_LOG_BLOCKS_PER_POLL = parseInt(process.env.MAX_LOG_BLOCKS_PER_POLL ?? "50");
const POLL_INTERVAL_MS_WHILE_BUSY = parseInt(process.env.POLL_INTERVAL_MS_WHILE_BUSY ?? "8000");
const MAX_CLOSE_FINALIZE_RETRIES = parseInt(process.env.MAX_CLOSE_FINALIZE_RETRIES ?? "5");

function sleep(ms: number) {
  return new Promise<void>(resolve => setTimeout(resolve, ms));
}

function isTooManyRequests(err: any): boolean {
  const msg =
    err?.message ??
    err?.error?.message ??
    err?.data?.message ??
    (typeof err === "string" ? err : undefined) ??
    "";
  return msg.includes("Too Many Requests") || msg.includes("-32005");
}

function isTemporarilyUnavailable(err: any): boolean {
  const msg =
    err?.message ??
    err?.error?.message ??
    err?.data?.message ??
    (typeof err === "string" ? err : undefined) ??
    "";
  const code = err?.code;
  return msg.includes("service temporarily unavailable") || code === -32603;
}

async function withRpcRetry<T>(fn: () => Promise<T>, label: string): Promise<T> {
  let lastErr: unknown = null;
  for (let attempt = 1; attempt <= RPC_RETRIES; attempt++) {
    try {
      return await fn();
    } catch (e) {
      lastErr = e;
      // Infura sometimes rate-limits `eth_getLogs` with `Too Many Requests` (-32005).
      // Back off harder for that specific class of error.
      const delay = isTooManyRequests(e)
        ? Math.min(180_000, 35_000 + (attempt - 1) * 15_000)
        : isTemporarilyUnavailable(e)
          ? Math.min(120_000, 10_000 + (attempt - 1) * 10_000)
          : Math.min(60_000, 500 * Math.pow(2, attempt - 1));
      console.warn(`[RPC retry ${attempt}/${RPC_RETRIES}] ${label} failed, retrying in ${Math.round(delay)}ms`);
      await sleep(delay);
    }
  }
  throw new Error(`[RPC retry] ${label} failed: ${lastErr instanceof Error ? lastErr.message : String(lastErr)}`);
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function decryptHandle(cofheClient: any, ctHash: bigint, label: string): Promise<{ value: bigint; sig: string }> {
  const ctHashHex = "0x" + ctHash.toString(16).padStart(64, "0");
  const permit = await cofheClient.permits.getOrCreateSelfPermit();

  for (let attempt = 1; attempt <= DECRYPT_RETRIES; attempt++) {
    try {
      const result = await cofheClient.decryptForTx(ctHashHex).withPermit(permit).execute();
      return { value: result.decryptedValue as bigint, sig: result.signature as string };
    } catch (err: any) {
      const msg = err?.message ?? String(err);
      if (attempt === DECRYPT_RETRIES) throw new Error(`decryptForTx[${label}] failed: ${msg}`);
      await new Promise(r => setTimeout(r, DECRYPT_RETRY_MS));
    }
  }
  throw new Error("unreachable");
}

async function queryFilterChunked(pm: Contract, filter: any, fromBlock: number, toBlock: number, chunkSize = 2000) {
  const results: EventLog[] = [];
  for (let from = fromBlock; from <= toBlock; from += chunkSize) {
    const to = Math.min(from + chunkSize - 1, toBlock);
    const chunk = await pm.queryFilter(filter, from, to);
    results.push(...(chunk as EventLog[]));
  }
  return results;
}

async function findPositionOpened(pm: Contract, positionKey: string, toBlock: number): Promise<EventLog | null> {
  // `positionKey` is indexed, so we expect at most one match.
  // Query it in a few coarse windows to avoid hammering the RPC with chunked scans.
  const filter = pm.filters.PositionOpened(positionKey);

  let to = toBlock;
  for (let i = 0; i < OPEN_LOOKBACK_STEPS; i++) {
    const from = Math.max(FROM_BLOCK, to - OPEN_LOOKBACK_WINDOW);
    const events = await withRpcRetry(
      () => pm.queryFilter(filter, from, to).then(chunk => chunk as EventLog[]),
      `pm.queryFilter(PositionOpened, ${from}..${to})`,
    );
    if (events.length > 0) return events[events.length - 1] as EventLog;
    if (from === FROM_BLOCK) break;
    to = from - 1;
  }
  return null;
}

// Serializes sends so concurrent decryptions don't race on nonce.
let txQueue = Promise.resolve();
function enqueue(fn: () => Promise<void>): void {
  txQueue = txQueue.then(fn).catch(() => {});
}

async function finalize(pm: Contract, cofheClient: any, positionKey: string, trader: string, finalAmountHandle: bigint, sizeHandle: bigint, collateralHandle: bigint) {
  console.log(`\n[Finalize] trader=${trader}`);
  console.log(`  positionKey: ${positionKey}`);

  const [finalAmountRes, sizeRes, collateralRes] = await Promise.all([
    decryptHandle(cofheClient, finalAmountHandle, "finalAmount"),
    decryptHandle(cofheClient, sizeHandle, "size"),
    decryptHandle(cofheClient, collateralHandle, "collateral"),
  ]);

  await new Promise<void>((resolve, reject) => {
    enqueue(async () => {
      try {
        const tx = await pm.finalizeClosePosition(
          positionKey,
          finalAmountRes.value,
          finalAmountRes.sig,
          sizeRes.value,
          sizeRes.sig,
          collateralRes.value,
          collateralRes.sig,
          false,
        );
        const receipt = await withRpcRetry<TransactionReceipt>(() => tx.wait(), "tx.wait");
        console.log(`  tx:    ${tx.hash}`);
        console.log(`  block: ${receipt?.blockNumber}  gas: ${receipt?.gasUsed}`);
        resolve();
      } catch (e) {
        reject(e);
      }
    });
  });
}

async function main() {
  // Infura DNS can be flaky in some environments.
  // NOTE: @cofhe/sdk's Ethers6Adapter does not accept ethers' FallbackProvider,
  // so we explicitly pick a working JsonRpcProvider here.
  const fallbackRpc = process.env.ARBITRUM_SEPOLIA_RPC_URL || "https://sepolia-rollup.arbitrum.io/rpc";

  async function pickProvider(): Promise<JsonRpcProvider> {
    const candidates = [RPC_URL, fallbackRpc].filter(Boolean);
    let lastErr: unknown = null;
    for (const url of candidates) {
      try {
        const p = new JsonRpcProvider(url);
        // Force a network call so we fail fast on DNS / connection issues.
        await p.getBlockNumber();
        console.log(`RPC:             ${url}`);
        return p;
      } catch (e) {
        lastErr = e;
      }
    }
    throw lastErr instanceof Error ? lastErr : new Error(String(lastErr));
  }

  const provider = await pickProvider();
  const wallet = new Wallet(PRIVATE_KEY, provider);
  const pm = new Contract(POOL2.POSITION_MANAGER, POSITION_MANAGER_ABI, wallet);

  console.log(`Close listener (Pool 2)`);
  console.log(`Wallet:          ${wallet.address}`);
  console.log(`PositionManager: ${POOL2.POSITION_MANAGER}`);
  console.log(`FROM_BLOCK:      ${FROM_BLOCK || "earliest"}  (set this near deployment to speed up)`);

  // CoFHE client
  const config = createCofheConfig({ supportedChains: [arbSepolia] });
  const cofheClient = createCofheClient(config);
  const { publicClient, walletClient } = await Ethers6Adapter(provider, wallet);
  await cofheClient.connect(publicClient, walletClient);

  const inFlight = new Set<string>();
  const scheduled = new Set<string>();
  const closeFinalizeAttempts = new Map<string, number>();
  type CloseEvent = { positionKey: string; trader: string; finalAmountHandleStr: string; sizeHandleStr: string; eventBlock?: number };
  const eventQueue: CloseEvent[] = [];
  async function handleCloseRequested(positionKey: string, trader: string, finalAmountHandleStr: string, sizeHandleStr: string, eventBlock?: number) {
    const key = positionKey.toLowerCase();
    if (inFlight.has(key)) {
      return;
    }
    inFlight.add(key);

    let success = false;
    try {
      const currentBlock = eventBlock ?? (await provider.getBlockNumber());
      let collateralHandle: bigint | null = null;

      // Cheap path: if the event trader is our wallet, read directly from contract storage.
      // This avoids RPC-heavy backward log searches that can trigger Infura rate limits.
      const walletAddr = wallet.address.toLowerCase();
      if (trader.toLowerCase() === walletAddr) {
        try {
          const pos = await withRpcRetry(() => pm.getMyPosition(positionKey), "pm.getMyPosition");
          collateralHandle = BigInt(pos.collateral as string);
        } catch (e) {
          collateralHandle = null;
        }
      }

      // Fallback: find collateralHandle from PositionOpened (works even when trader != wallet).
      if (!collateralHandle || collateralHandle === 0n) {
        const opened = await findPositionOpened(pm, positionKey, currentBlock);
        if (opened) collateralHandle = BigInt(opened.args[3] as string);
      }

      if (!collateralHandle || collateralHandle === 0n) {
        console.warn(`[Skip] collateral handle not found for ${positionKey} (no PositionOpened event; getMyPosition failed)`);
        return;
      }
      await finalize(
        pm,
        cofheClient,
        positionKey,
        trader,
        BigInt(finalAmountHandleStr),
        BigInt(sizeHandleStr),
        collateralHandle,
      );
      success = true;
    } catch (err: any) {
      console.error(`[Error] finalize failed for ${positionKey}:`, err?.message ?? err);
      const nextAttempts = (closeFinalizeAttempts.get(key) ?? 0) + 1;
      closeFinalizeAttempts.set(key, nextAttempts);

      if (nextAttempts < MAX_CLOSE_FINALIZE_RETRIES) {
        const backoffMs = Math.min(120_000, 3_000 * Math.pow(2, nextAttempts - 1));
        console.warn(`[Retry] scheduling finalize retry ${nextAttempts}/${MAX_CLOSE_FINALIZE_RETRIES} in ${backoffMs}ms`);
        await sleep(backoffMs);
        eventQueue.push({
          positionKey,
          trader,
          finalAmountHandleStr,
          sizeHandleStr,
          eventBlock,
        });
      } else {
        console.error(`[Drop] finalize retries exhausted for ${positionKey}`);
        scheduled.delete(key);
      }
    } finally {
      inFlight.delete(key);
      if (success) {
        closeFinalizeAttempts.delete(key);
        scheduled.delete(key);
      }
    }
  }

  // Process close events sequentially, while the poll loop continues fetching new blocks.
  (async () => {
    while (true) {
      const next = eventQueue.shift();
      if (!next) {
        await sleep(250);
        continue;
      }
      await handleCloseRequested(next.positionKey, next.trader, next.finalAmountHandleStr, next.sizeHandleStr, next.eventBlock);
    }
  })().catch(console.error);

  const closeRequestedFilter = pm.filters.CloseRequested();
  let lastProcessedBlock: number;
  if (REPLAY) {
    const latest = await withRpcRetry(() => provider.getBlockNumber(), "provider.getBlockNumber()");
    const start = FROM_BLOCK || Math.max(0, latest - 200_000);
    console.log(`\nReplaying CloseRequested from ${start}..${latest}...`);
    const past = await withRpcRetry(
      () => queryFilterChunked(pm, closeRequestedFilter, start, latest, LOG_CHUNK_SIZE),
      "queryFilterChunked(CloseRequested, replay)",
    );
    for (const evt of past as EventLog[]) {
      const positionKey = evt.args[0] as string;
      const trader = evt.args[1] as string;
      const finalAmountHandle = evt.args[2] as string;
      const sizeHandle = evt.args[3] as string;
      await handleCloseRequested(positionKey, trader, finalAmountHandle, sizeHandle, evt.blockNumber);
    }
    lastProcessedBlock = latest;
  } else {
    const latest = await withRpcRetry(() => provider.getBlockNumber(), "provider.getBlockNumber()");
    // If FROM_BLOCK is explicitly set, respect it; otherwise start from "latest - 1" to reduce misses.
    lastProcessedBlock = FROM_BLOCK || Math.max(0, latest - 1);
  }

  console.log(`\nPolling for CloseRequested... (lastProcessedBlock=${lastProcessedBlock})`);
  while (true) {
    try {
      const latest = await withRpcRetry(() => provider.getBlockNumber(), "provider.getBlockNumber()");
      const from = lastProcessedBlock + 1;
      if (from <= latest) {
        const to = Math.min(latest, from + MAX_LOG_BLOCKS_PER_POLL - 1);
        const events = await withRpcRetry(
          () => queryFilterChunked(pm, closeRequestedFilter, from, to, Math.min(LOG_CHUNK_SIZE, to - from + 1)),
          `queryFilterChunked(CloseRequested, ${from}..${to})`,
        );
        for (const evt of events as EventLog[]) {
          const positionKey = evt.args[0] as string;
          const trader = evt.args[1] as string;
          const finalAmountHandle = evt.args[2] as string;
          const sizeHandle = evt.args[3] as string;
          const qKey = positionKey.toLowerCase();
          if (scheduled.has(qKey)) continue;
          scheduled.add(qKey);
          eventQueue.push({
            positionKey,
            trader,
            finalAmountHandleStr: finalAmountHandle,
            sizeHandleStr: sizeHandle,
            eventBlock: evt.blockNumber,
          });
          console.log(`\n[Event] CloseRequested block=${evt.blockNumber} trader=${trader} positionKey=${positionKey}`);
        }
        lastProcessedBlock = to;
      }
    } catch (e: any) {
      console.error(`[Polling error]`, e?.message ?? e);
      // Avoid tight retry loops in case of persistent RPC failures.
    }
    const isBusy = eventQueue.length > 0;
    await sleep(isBusy ? POLL_INTERVAL_MS_WHILE_BUSY : POLL_INTERVAL_MS);
  }

  process.stdin.resume();
}

main().catch(console.error);

