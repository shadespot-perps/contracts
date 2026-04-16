/**
 * open-position.ts — Pool 1 (Router.sol, USDC collateral)
 *
 * Flow:
 *   1. setPrice   — refresh oracle (5-min TTL)
 *   2. approve    — USDC allowance to Router
 *   3. openPosition
 */

import { ethers, Wallet, JsonRpcProvider, Contract } from "ethers";
import { RPC_URL, PRIVATE_KEY, INDEX_TOKEN, POOL1 } from "./config";

// ── Minimal ABIs ─────────────────────────────────────────────────────────────

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function allowance(address owner, address spender) external view returns (uint256)",
  "function balanceOf(address) external view returns (uint256)",
  "function mint(address to, uint256 amount) external",
];

const ORACLE_ABI = [
  "function setPrice(address token, uint256 price) external",
  "function getPrice(address token) external view returns (uint256)",
  "function getPriceData(address token) external view returns (uint256 price, uint256 lastUpdated)",
];

const ROUTER_ABI = [
  "function openPosition(address token, uint256 collateral, uint256 leverage, bool isLong) external",
  "function closePosition(address token, bool isLong) external",
  "function indexToken() external view returns (address)",
  "event OpenPosition(address indexed trader, address token, uint256 collateral, uint256 leverage, bool isLong)",
];

// ── Params (edit these) ───────────────────────────────────────────────────────

const COLLATERAL_AMOUNT = 10_000_000n;  // 10 USDC  (6 decimals)
const LEVERAGE          = 5n;
const IS_LONG           = true;
const ETH_PRICE_8DEC    = 320_000_000_000n; // $3200 (8 decimals)

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const provider = new JsonRpcProvider(RPC_URL);
  const wallet   = new Wallet(PRIVATE_KEY, provider);

  const usdc   = new Contract(POOL1.USDC,   ERC20_ABI,  wallet);
  const oracle = new Contract(POOL1.ORACLE, ORACLE_ABI, wallet);
  const router = new Contract(POOL1.ROUTER, ROUTER_ABI, wallet);

  console.log("Wallet:   ", wallet.address);
  console.log("Collateral:", COLLATERAL_AMOUNT.toString(), "USDC units");

  // 1. Mint test USDC if balance is low
  const balance = await usdc.balanceOf(wallet.address);
  console.log("\nUSDC balance:", balance.toString());
  if (balance < COLLATERAL_AMOUNT) {
    console.log("Minting 100 USDC...");
    const tx = await usdc.mint(wallet.address, 100_000_000n);
    await tx.wait();
    console.log("Minted:", tx.hash);
  }

  // 2. Refresh oracle price (must be < 5 min old)
  console.log("\nRefreshing oracle price to $" + (Number(ETH_PRICE_8DEC) / 1e8).toFixed(2));
  const oracleTx = await oracle.setPrice(INDEX_TOKEN, ETH_PRICE_8DEC);
  await oracleTx.wait();
  console.log("Oracle tx:", oracleTx.hash);

  // 3. Approve Router to spend USDC
  const allowance = await usdc.allowance(wallet.address, POOL1.ROUTER);
  if (allowance < COLLATERAL_AMOUNT) {
    console.log("\nApproving Router for", COLLATERAL_AMOUNT.toString(), "USDC...");
    const approveTx = await usdc.approve(POOL1.ROUTER, COLLATERAL_AMOUNT);
    await approveTx.wait();
    console.log("Approve tx:", approveTx.hash);
  } else {
    console.log("\nAllowance already sufficient:", allowance.toString());
  }

  // 4. Open position
  console.log("\nOpening position:");
  console.log("  token    :", INDEX_TOKEN);
  console.log("  collateral:", COLLATERAL_AMOUNT.toString());
  console.log("  leverage  :", LEVERAGE.toString() + "x");
  console.log("  isLong    :", IS_LONG);

  const openTx = await router.openPosition(
    INDEX_TOKEN,
    COLLATERAL_AMOUNT,
    LEVERAGE,
    IS_LONG,
  );
  const receipt = await openTx.wait();
  console.log("\nOpenPosition tx:", openTx.hash);
  console.log("Block:          ", receipt?.blockNumber);
  console.log("Gas used:       ", receipt?.gasUsed.toString());

  // Parse OpenPosition event
  const iface  = new ethers.Interface(ROUTER_ABI);
  for (const log of receipt?.logs ?? []) {
    try {
      const parsed = iface.parseLog({ topics: [...log.topics], data: log.data });
      if (parsed?.name === "OpenPosition") {
        console.log("\nEvent OpenPosition:");
        console.log("  trader    :", parsed.args.trader);
        console.log("  collateral:", parsed.args.collateral.toString());
        console.log("  leverage  :", parsed.args.leverage.toString());
        console.log("  isLong    :", parsed.args.isLong);
      }
    } catch {}
  }
}

main().catch(console.error);
