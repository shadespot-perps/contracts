/**
 * close-position.ts — Pool 1 (Router.sol)
 *
 * Flow:
 *   1. setPrice   — refresh oracle (5-min TTL)
 *   2. closePosition
 *   3. Parse PositionClosed + ClosePosition events
 */

import { ethers, Wallet, JsonRpcProvider, Contract } from "ethers";
import { RPC_URL, PRIVATE_KEY, INDEX_TOKEN, POOL1 } from "./config";

const ORACLE_ABI = [
  "function setPrice(address token, uint256 price) external",
];

const ROUTER_ABI = [
  "function closePosition(address token, bool isLong) external",
  "event ClosePosition(address indexed trader, address token, bool isLong)",
];

const POSITION_MANAGER_ABI = [
  "event PositionClosed(bytes32 indexed positionKey, address indexed trader, address indexed token, bool isLong, bytes32 settlementHandle)",
];

// ── Params ────────────────────────────────────────────────────────────────────

const IS_LONG        = true;
const ETH_PRICE_8DEC = 320_000_000_000n; // $3200 (8 decimals)

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const provider = new JsonRpcProvider(RPC_URL);
  const wallet   = new Wallet(PRIVATE_KEY, provider);

  const oracle = new Contract(POOL1.ORACLE, ORACLE_ABI, wallet);
  const router = new Contract(POOL1.ROUTER, ROUTER_ABI, wallet);

  console.log("Wallet:", wallet.address);

  // 1. Refresh oracle price — must be within 5 minutes
  console.log("\nRefreshing oracle price...");
  const oracleTx = await oracle.setPrice(INDEX_TOKEN, ETH_PRICE_8DEC);
  await oracleTx.wait();
  console.log("Oracle tx:", oracleTx.hash);

  // 2. Close position
  console.log("\nClosing position:");
  console.log("  token :", INDEX_TOKEN);
  console.log("  isLong:", IS_LONG);

  const closeTx = await router.closePosition(INDEX_TOKEN, IS_LONG);
  const receipt  = await closeTx.wait();

  console.log("\nClosePosition tx:", closeTx.hash);
  console.log("Block:           ", receipt?.blockNumber);
  console.log("Gas used:        ", receipt?.gasUsed.toString());

  // 3. Parse events
  const routerIface = new ethers.Interface(ROUTER_ABI);
  const pmIface     = new ethers.Interface(POSITION_MANAGER_ABI);

  for (const log of receipt?.logs ?? []) {
    try {
      const parsed = routerIface.parseLog({ topics: [...log.topics], data: log.data });
      if (parsed?.name === "ClosePosition") {
        console.log("\nEvent ClosePosition:");
        console.log("  trader:", parsed.args.trader);
        console.log("  token :", parsed.args.token);
        console.log("  isLong:", parsed.args.isLong);
      }
    } catch {}

    try {
      const parsed = pmIface.parseLog({ topics: [...log.topics], data: log.data });
      if (parsed?.name === "PositionClosed") {
        console.log("\nEvent PositionClosed:");
        console.log("  positionKey     :", parsed.args.positionKey);
        console.log("  settlementHandle:", parsed.args.settlementHandle);
        console.log("  (settlementHandle is the encrypted net payout — awaits CoFHE decrypt)");
      }
    } catch {}
  }
}

main().catch(console.error);
