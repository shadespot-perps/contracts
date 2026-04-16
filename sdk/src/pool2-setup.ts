/**
 * pool2-setup.ts — Pool 2 (FHERouter.sol) one-time operator grant
 *
 * Pool 2 uses confidentialTransferFrom instead of ERC-20 transferFrom.
 * Standard approve() deliberately reverts on MockFHEToken.
 * Instead, grant FHERouter operator status once before your first trade.
 *
 * Run once per wallet, then use pool2-open.ts / pool2-close.ts.
 */

import { Wallet, JsonRpcProvider, Contract } from "ethers";
import { RPC_URL, PRIVATE_KEY, POOL2 } from "./config";

const FHE_TOKEN_ABI = [
  // Operator model — replaces approve
  "function setOperator(address operator, uint48 untilTimestamp) external",
  "function isOperator(address owner, address operator) external view returns (bool)",

  // Mint for testing — uint64 matches MockFHEToken.mint(address, uint64)
  "function mint(address to, uint64 amount) external",
];

async function main() {
  const provider = new JsonRpcProvider(RPC_URL);
  const wallet   = new Wallet(PRIVATE_KEY, provider);
  const fheToken = new Contract(POOL2.FHE_TOKEN, FHE_TOKEN_ABI, wallet);

  console.log("Wallet:    ", wallet.address);
  console.log("FHERouter: ", POOL2.FHE_ROUTER);

  // Check if already operator
  const already = await fheToken.isOperator(wallet.address, POOL2.FHE_ROUTER);
  if (already) {
    console.log("\nFHERouter is already an operator. Nothing to do.");
    return;
  }

  // Mint test FHE tokens if needed
  // (balanceOf returns an encrypted handle on FHERC20 — use plaintext mock mint)
  console.log("\nMinting 1000 FHE token units to wallet...");
  const mintTx = await fheToken.mint(wallet.address, 100_000_000n); // uint64, fits well within range
  await mintTx.wait();
  console.log("Mint tx:", mintTx.hash);

  // Grant operator status for ~100 years
  const untilTimestamp = Math.floor(Date.now() / 1000) + 100 * 365 * 24 * 3600;
  console.log("\nGranting FHERouter operator status until timestamp:", untilTimestamp);

  const tx = await fheToken.setOperator(POOL2.FHE_ROUTER, untilTimestamp);
  await tx.wait();
  console.log("setOperator tx:", tx.hash);

  // Verify
  const isOp = await fheToken.isOperator(wallet.address, POOL2.FHE_ROUTER);
  console.log("\nisOperator now:", isOp);
}

main().catch(console.error);
