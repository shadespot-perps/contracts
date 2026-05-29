/**
 * update-price.ts — Refresh stale oracle prices on both pools (runs once).
 *
 * Flow:
 *   1. Fetch current ETH/USD price from CoinGecko public API
 *   2. Call PriceOracle.setPrice(INDEX_TOKEN, price) on Pool 1
 *   3. Call PriceOracle.setPrice(INDEX_TOKEN, price) on Pool 2
 *
 * The oracle uses 8-decimal fixed-point (e.g. $3200.00 → 320_000_000_000).
 * Caller must be the oracle owner (PRIVATE_KEY in .env).
 *
 * Run: npx ts-node src/update-price.ts
 */

import { Wallet, JsonRpcProvider, Contract } from "ethers";
import { RPC_URL, PRIVATE_KEY, INDEX_TOKEN, POOL1, POOL2 } from "./config";

const ORACLE_ABI = [
  "function setPrice(address token, uint256 price) external",
  "function getPriceData(address token) external view returns (uint256 price, uint256 lastUpdated)",
  "function owner() external view returns (address)",
];

const PRICE_DECIMALS = 8;

async function fetchEthPrice(): Promise<number> {
  // CoinGecko is rate-limited on public endpoints; for dev/testnet we mock ETH/USD.
  // Range: [2000, 3000)
  const mocked = 2000 + Math.random() * 1000;
  return Math.round(mocked * 100) / 100;
}

function toPriceUnits(usdPrice: number): bigint {
  return BigInt(Math.round(usdPrice * 10 ** PRICE_DECIMALS));
}

async function updateOracle(
  oracle: Contract,
  token: string,
  priceUnits: bigint,
  label: string,
): Promise<void> {
  const [currentPrice, lastUpdated] = await oracle.getPriceData(token) as [bigint, bigint];
  const age = Math.floor(Date.now() / 1000) - Number(lastUpdated);

  console.log(`\n${label}`);
  console.log(`  Last price  : $${(Number(currentPrice) / 10 ** PRICE_DECIMALS).toFixed(2)}`);
  console.log(`  Last updated: ${lastUpdated > 0n ? `${age}s ago` : "never"}`);
  console.log(`  New price   : $${(Number(priceUnits) / 10 ** PRICE_DECIMALS).toFixed(2)}`);

  const tx = await oracle.setPrice(token, priceUnits);
  console.log(`  Tx hash     : ${tx.hash}`);
  const receipt = await tx.wait();
  console.log(`  Confirmed   : block ${receipt?.blockNumber}, gas ${receipt?.gasUsed}`);
}

async function main() {
  const provider = new JsonRpcProvider(RPC_URL);
  const wallet   = new Wallet(PRIVATE_KEY, provider);

  console.log("Wallet     :", wallet.address);
  console.log("Index token:", INDEX_TOKEN);

  // Fetch mocked price
  console.log("\nMocking ETH price (CoinGecko disabled)...");
  const ethUsd    = await fetchEthPrice();
  const priceUnits = toPriceUnits(ethUsd);
  console.log(`ETH/USD: $${ethUsd.toFixed(2)} → ${priceUnits} (8-dec)`);

  const oracle1 = new Contract(POOL1.ORACLE, ORACLE_ABI, wallet);
  const oracle2 = new Contract(POOL2.ORACLE, ORACLE_ABI, wallet);

  await updateOracle(oracle1, INDEX_TOKEN, priceUnits, "Pool 1 Oracle");
  await updateOracle(oracle2, INDEX_TOKEN, priceUnits, "Pool 2 Oracle");

  console.log("\nDone — both oracles updated.");
}

main().catch((err) => {
  console.error("Error:", err.message ?? err);
  process.exit(1);
});
