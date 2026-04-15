/**
 * pool2-add-liquidity.ts
 *
 * Deposits liquidity into FHEVault (Pool 2) so openPosition can reserve against it.
 * FHEVault.deposit() only does FHE.add — no decrypt task needed, runs in one tx.
 *
 * Prerequisites: pool2-setup.ts must have been run (setOperator granted).
 */

import { ethers, Wallet, JsonRpcProvider, Contract } from "ethers";
import { RPC_URL, PRIVATE_KEY, POOL2 } from "./config";

const ORACLE_ABI = [
  "function setPrice(address token, uint256 price) external",
];

const FHE_ROUTER_ABI = [
  "function addLiquidity(uint256 amount) external",
  "event AddLiquidity(address indexed user, uint256 amount)",
];

const FHE_TOKEN_ABI = [
  "function isOperator(address owner, address operator) external view returns (bool)",
];

const AMOUNT       = 50_000_000n;  // 50 units — enough to back a 5x 10-unit position
const INDEX_TOKEN  = process.env.INDEX_TOKEN!;
const ETH_PRICE    = 320_000_000_000n;

async function main() {
  const provider  = new JsonRpcProvider(RPC_URL);
  const wallet    = new Wallet(PRIVATE_KEY, provider);
  const oracle    = new Contract(POOL2.ORACLE,     ORACLE_ABI,     wallet);
  const fheRouter = new Contract(POOL2.FHE_ROUTER, FHE_ROUTER_ABI, wallet);
  const fheToken  = new Contract(POOL2.FHE_TOKEN,  FHE_TOKEN_ABI,  wallet);

  console.log("Wallet:", wallet.address);

  const isOp = await fheToken.isOperator(wallet.address, POOL2.FHE_ROUTER);
  if (!isOp) {
    console.error("ERROR: FHERouter is not an operator. Run pool2:setup first.");
    process.exit(1);
  }

  // Refresh oracle (required before any vault interaction that touches PositionManager)
  console.log("Refreshing Pool 2 oracle...");
  const oTx = await oracle.setPrice(INDEX_TOKEN, ETH_PRICE);
  await oTx.wait();
  console.log("Oracle tx:", oTx.hash);

  console.log("\nAdding", AMOUNT.toString(), "units of liquidity to FHEVault...");
  const tx      = await fheRouter.addLiquidity(AMOUNT);
  const receipt = await tx.wait();

  console.log("addLiquidity tx:", tx.hash);
  console.log("Gas used:       ", receipt?.gasUsed.toString());

  const iface = new ethers.Interface(FHE_ROUTER_ABI);
  for (const log of receipt?.logs ?? []) {
    try {
      const parsed = iface.parseLog({ topics: [...log.topics], data: log.data });
      if (parsed?.name === "AddLiquidity") {
        console.log("\nEvent AddLiquidity:");
        console.log("  user  :", parsed.args.user);
        console.log("  amount:", parsed.args.amount.toString());
      }
    } catch {}
  }
}

main().catch(console.error);
