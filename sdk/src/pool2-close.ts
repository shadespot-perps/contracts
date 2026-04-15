/**
 * pool2-close.ts — Pool 2 (FHERouter.sol)
 */

import { ethers, Wallet, JsonRpcProvider, Contract } from "ethers";
import { RPC_URL, PRIVATE_KEY, INDEX_TOKEN, POOL2 } from "./config";

const ORACLE_ABI = [
  "function setPrice(address token, uint256 price) external",
];

const FHE_ROUTER_ABI = [
  "function closePosition(address token, bool isLong) external",
  "event ClosePosition(address indexed trader, address token, bool isLong)",
];

const IS_LONG        = true;
const ETH_PRICE_8DEC = 320_000_000_000n;

async function main() {
  const provider  = new JsonRpcProvider(RPC_URL);
  const wallet    = new Wallet(PRIVATE_KEY, provider);
  const oracle    = new Contract(POOL2.ORACLE,     ORACLE_ABI,     wallet);
  const fheRouter = new Contract(POOL2.FHE_ROUTER, FHE_ROUTER_ABI, wallet);

  console.log("Wallet:", wallet.address);

  console.log("\nRefreshing Pool 2 oracle...");
  const oTx = await oracle.setPrice(INDEX_TOKEN, ETH_PRICE_8DEC);
  await oTx.wait();
  console.log("Oracle tx:", oTx.hash);

  console.log("\nClosing FHE position...");
  const closeTx = await fheRouter.closePosition(INDEX_TOKEN, IS_LONG);
  const receipt  = await closeTx.wait();

  console.log("\nClosePosition tx:", closeTx.hash);
  console.log("Gas used:        ", receipt?.gasUsed.toString());

  const iface = new ethers.Interface(FHE_ROUTER_ABI);
  for (const log of receipt?.logs ?? []) {
    try {
      const parsed = iface.parseLog({ topics: [...log.topics], data: log.data });
      if (parsed?.name === "ClosePosition") {
        console.log("\nEvent ClosePosition:", parsed.args);
      }
    } catch {}
  }
}

main().catch(console.error);
