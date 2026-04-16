/**
 * pool2-open.ts — Pool 2 (FHERouter.sol, FHE token collateral)
 *
 * Prerequisites:
 *   1. pool2:setup          — setOperator granted once
 *   2. pool2:add-liquidity  — FHEVault needs liquidity before reserveLiquidity runs
 *
 * CoFHE two-phase decrypt pattern:
 *   FHEVault.reserveLiquidity() calls FHE.getDecryptResultSafe() to verify
 *   totalLiquidity >= reserveAmount.  On live CoFHE this is async:
 *
 *   Phase A — submitDecryptTaskForOpen():
 *     Computes the encrypted comparison and calls createDecryptTask() in a
 *     transaction that SUCCEEDS (no revert).  The TaskCreated event is committed
 *     to the chain so the CoFHE dispatcher can see and process it.
 *
 *   Phase B — openPosition():
 *     FHEVault finds the pending check result via pendingLiqCheck[trader].
 *     If the dispatcher has published the result, the call succeeds.
 *     If not yet published, it reverts "decrypt not ready" — we retry Phase B.
 *
 *   This script runs Phase A once per attempt and retries Phase B until success.
 */

import { ethers, Wallet, JsonRpcProvider, Contract } from "ethers";
import { RPC_URL, PRIVATE_KEY, INDEX_TOKEN, POOL2 } from "./config";

const ORACLE_ABI = [
  "function setPrice(address token, uint256 price) external",
];

const FHE_TOKEN_ABI = [
  "function isOperator(address owner, address operator) external view returns (bool)",
];

const FHE_ROUTER_ABI = [
  "function submitDecryptTaskForOpen(address token, uint256 collateral, uint256 leverage) external",
  "function openPosition(address token, uint256 collateral, uint256 leverage, bool isLong) external",
  "event OpenPosition(address indexed trader, address token, uint256 collateral, uint256 leverage, bool isLong)",
];

// ── Params ────────────────────────────────────────────────────────────────────

const COLLATERAL_AMOUNT = 10_000_000n;
const LEVERAGE          = 5n;
const IS_LONG           = true;
const ETH_PRICE_8DEC    = 320_000_000_000n;

const MAX_RETRIES            = 20;
const SUBMIT_WAIT_MS         = 20_000; // 20s — give dispatcher time after Phase A
const RETRY_INTERVAL_MS      = 15_000; // 15s — between Phase B retries

// ── Helpers ───────────────────────────────────────────────────────────────────

function isDecryptNotReady(err: any): boolean {
  return err?.reason === "decrypt not ready" ||
    err?.shortMessage?.includes("decrypt not ready") ||
    err?.info?.error?.message?.includes("decrypt not ready");
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const provider  = new JsonRpcProvider(RPC_URL);
  const wallet    = new Wallet(PRIVATE_KEY, provider);
  const oracle    = new Contract(POOL2.ORACLE,     ORACLE_ABI,     wallet);
  const fheToken  = new Contract(POOL2.FHE_TOKEN,  FHE_TOKEN_ABI,  wallet);
  const fheRouter = new Contract(POOL2.FHE_ROUTER, FHE_ROUTER_ABI, wallet);

  console.log("Wallet:    ", wallet.address);

  const isOp = await fheToken.isOperator(wallet.address, POOL2.FHE_ROUTER);
  if (!isOp) {
    console.error("ERROR: FHERouter is not an operator. Run pool2:setup first.");
    process.exit(1);
  }

  console.log("\nOpenPosition params:");
  console.log("  collateral:", COLLATERAL_AMOUNT.toString());
  console.log("  leverage  :", LEVERAGE.toString() + "x");
  console.log("  isLong    :", IS_LONG);

  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    console.log(`\n[Attempt ${attempt}/${MAX_RETRIES}]`);

    // ── Phase A: refresh oracle + submit decrypt task ─────────────────────────
    // This transaction SUCCEEDS, so the TaskCreated event is committed and the
    // CoFHE dispatcher can process the encrypted comparison.
    console.log("  Refreshing oracle...");
    const oTx = await oracle.setPrice(INDEX_TOKEN, ETH_PRICE_8DEC);
    await oTx.wait();
    console.log("  oracle tx:", oTx.hash);

    console.log("  Submitting decrypt task (Phase A)...");
    const submitTx = await fheRouter.submitDecryptTaskForOpen(
      INDEX_TOKEN, COLLATERAL_AMOUNT, LEVERAGE,
    );
    await submitTx.wait();
    console.log("  submit tx:", submitTx.hash);
    console.log(`  Waiting ${SUBMIT_WAIT_MS / 1000}s for CoFHE dispatcher to publish result...`);
    await new Promise(r => setTimeout(r, SUBMIT_WAIT_MS));

    // ── Phase B: open position ────────────────────────────────────────────────
    // FHEVault finds pendingLiqCheck[trader] and reads the dispatcher result.
    try {
      console.log("  Sending openPosition (Phase B)...");
      const openTx = await fheRouter.openPosition(
        INDEX_TOKEN, COLLATERAL_AMOUNT, LEVERAGE, IS_LONG,
      );
      const receipt = await openTx.wait();

      console.log("\nOpenPosition tx:", openTx.hash);
      console.log("Block:          ", receipt?.blockNumber);
      console.log("Gas used:       ", receipt?.gasUsed.toString());

      const iface = new ethers.Interface(FHE_ROUTER_ABI);
      for (const log of receipt?.logs ?? []) {
        try {
          const parsed = iface.parseLog({ topics: [...log.topics], data: log.data });
          if (parsed?.name === "OpenPosition") {
            console.log("\nEvent OpenPosition:");
            console.log("  trader    :", parsed.args.trader);
            console.log("  collateral:", parsed.args.collateral.toString());
            console.log("  leverage  :", parsed.args.leverage.toString());
          }
        } catch {}
      }
      return; // success

    } catch (err: any) {
      if (isDecryptNotReady(err)) {
        // Dispatcher hasn't published the result yet — pendingLiqCheck stays set,
        // so the next attempt's Phase B will retry with the same handle.
        console.log(`  "decrypt not ready" — dispatcher hasn't published yet.`);
        console.log(`  Waiting ${RETRY_INTERVAL_MS / 1000}s before next attempt...`);
        await new Promise(r => setTimeout(r, RETRY_INTERVAL_MS));
      } else {
        throw err; // real error — surface immediately
      }
    }
  }

  console.error(`\nFailed after ${MAX_RETRIES} attempts.`);
  console.error("CoFHE dispatcher may not be active on Arbitrum Sepolia.");
  console.error("TaskManager:", "0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9");
  process.exit(1);
}

main().catch(console.error);
