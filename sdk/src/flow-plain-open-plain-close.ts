/**
 * flow-plain-open-plain-close.ts
 *
 * Flow: Open with plain ERC-20 collateral → Close with plain ERC-20 payout
 *
 * Both entry and exit use plain ERC-20. The position itself (collateral, size,
 * direction) is still stored encrypted inside PositionManager throughout.
 *
 * Prerequisites:
 *   npm run pool2:setup  (grants FHERouter as operator, mints 100M FHE tokens — run once)
 *   Wallet must hold underlying ERC-20 tokens (queried from router.underlyingToken())
 *
 * What this script does end-to-end:
 *   1. Reads current oracle price (read-only — no owner required)
 *   2. Seeds vault with encrypted liquidity from your FHE token balance
 *   3. Approves router to pull plain ERC-20 collateral
 *   4. Phase A — submitOpenPositionCheckPlain: pulls & wraps plain ERC-20, submits liquidity check
 *   5. Phase B — finalizeOpenPositionPlain: verifies CoFHE result, opens encrypted position
 *   6. requestClosePlainPayout: user flags position for plain ERC-20 payout
 *   7. finalizeClosePlainPayout: keeper settles PnL, sends plain ERC-20 to trader
 */

import { ethers, Wallet, JsonRpcProvider, Contract } from "ethers";
import { RPC_URL, PRIVATE_KEY, INDEX_TOKEN, POOL2 } from "./config";

// ── ABI fragments ─────────────────────────────────────────────────────────────

const ORACLE_ABI = [
  "function getPrice(address token) external view returns (uint256)",
];

const UNDERLYING_ABI = [
  "function approve(address spender, uint256 amount) external returns (bool)",
  "function balanceOf(address account) external view returns (uint256)",
];

const FHE_TOKEN_ABI = [
  "function isOperator(address owner, address operator) external view returns (bool)",
];

const S = "tuple(uint256 ctHash, uint8 securityZone, uint8 utype, bytes signature)";

const FHE_ROUTER_ABI = [
  "function underlyingToken() external view returns (address)",
  `function addLiquidity(${S} encAmount) external`,
  `function submitOpenPositionCheckPlain(address token, uint64 plainCollateral, ${S} encLeverage, ${S} encIsLong) external`,
  "function finalizeOpenPositionPlain(address token, bool hasLiqPlain, bytes hasLiqSig) external returns (bytes32)",
  "function requestClosePlainPayout(bytes32 positionId) external",
  "function finalizeClosePlainPayout(bytes32 positionId, uint256 finalAmount, bytes finalAmountSig, uint256 sizePlain, bytes sizeSig, uint256 collateralPlain, bytes collateralSig, bool isLongPlain) external",
  "event OpenPosition(bytes32 indexed positionKey, address indexed trader)",
  "event PlainPayoutSettled(bytes32 indexed positionKey, address indexed trader, uint64 amount)",
];

// ── Trade params ──────────────────────────────────────────────────────────────

const PLAIN_COLLATERAL  = 10_000_000n;
const LEVERAGE          = 5n;
const IS_LONG           = true;
const VAULT_SEED        = 60_000_000n;  // encrypted liquidity to seed vault (>= PLAIN_COLLATERAL*LEVERAGE)

// Keeper values — on real CoFHE these come from the dispatcher after decryption.
const FINAL_AMOUNT      = PLAIN_COLLATERAL;         // breakeven demo
const SIZE_PLAIN        = PLAIN_COLLATERAL * LEVERAGE;

const MAX_RETRIES       = 20;
const SUBMIT_WAIT_MS    = 20_000;
const RETRY_INTERVAL_MS = 15_000;

// ── Helpers ───────────────────────────────────────────────────────────────────

function inEuint64(val: bigint) {
  return { ctHash: val, securityZone: 0, utype: 5, signature: "0x" };
}
function inEbool(val: boolean) {
  return { ctHash: val ? 1n : 0n, securityZone: 0, utype: 0, signature: "0x" };
}
function isDecryptNotReady(err: any): boolean {
  return (
    err?.reason === "decrypt not ready" ||
    err?.shortMessage?.includes("decrypt not ready") ||
    err?.info?.error?.message?.includes("decrypt not ready")
  );
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const provider  = new JsonRpcProvider(RPC_URL);
  const wallet    = new Wallet(PRIVATE_KEY, provider);
  const oracle    = new Contract(POOL2.ORACLE,     ORACLE_ABI,     wallet);
  const fheToken  = new Contract(POOL2.FHE_TOKEN,  FHE_TOKEN_ABI,  wallet);
  const fheRouter = new Contract(POOL2.FHE_ROUTER, FHE_ROUTER_ABI, wallet);

  console.log("Wallet:", wallet.address);
  console.log("Flow:   plain-open → plain-close\n");

  // ── Prerequisites ──────────────────────────────────────────────────────────

  const isOp = await fheToken.isOperator(wallet.address, POOL2.FHE_ROUTER);
  if (!isOp) {
    console.error("FHERouter is not an operator. Run 'npm run pool2:setup' first.");
    process.exit(1);
  }

  // Read oracle price (read-only — setPrice requires owner)
  const currentPrice: bigint = await oracle.getPrice(INDEX_TOKEN);
  console.log("Oracle price:", currentPrice.toString());
  if (currentPrice === 0n) {
    console.warn("WARNING: Oracle price is 0 — ask the contract owner to set a price.");
  }

  // Check underlying token and user balance
  const underlyingAddr: string = await fheRouter.underlyingToken();
  console.log("Underlying token:", underlyingAddr);
  const underlying = new Contract(underlyingAddr, UNDERLYING_ABI, wallet);
  const underlyingBal: bigint = await underlying.balanceOf(wallet.address);
  console.log("Underlying balance:", underlyingBal.toString());
  if (underlyingBal < PLAIN_COLLATERAL) {
    console.error(`Insufficient underlying balance. Need ${PLAIN_COLLATERAL}, have ${underlyingBal}.`);
    process.exit(1);
  }

  // ── Seed vault liquidity (encrypted FHE tokens, no oracle needed) ─────────

  console.log(`\nSeeding vault with ${VAULT_SEED} encrypted units...`);
  const liqTx = await fheRouter.addLiquidity(inEuint64(VAULT_SEED));
  await liqTx.wait();
  console.log("Vault seeded:", liqTx.hash);

  // Approve router to pull plain ERC-20 collateral in Phase A
  console.log(`\nApproving router for ${PLAIN_COLLATERAL} underlying...`);
  const approveTx = await underlying.approve(POOL2.FHE_ROUTER, PLAIN_COLLATERAL);
  await approveTx.wait();
  console.log("Approve tx:", approveTx.hash);

  // ── OPEN: two-phase ───────────────────────────────────────────────────────

  let positionId: string | undefined;

  for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
    console.log(`\n[Open attempt ${attempt}/${MAX_RETRIES}]`);

    // Phase A — pull plain ERC-20, wrap to encrypted, submit liquidity check
    const submitTx = await fheRouter.submitOpenPositionCheckPlain(
      INDEX_TOKEN,
      PLAIN_COLLATERAL,
      inEuint64(LEVERAGE),
      inEbool(IS_LONG),
    );
    await submitTx.wait();
    console.log("  submitOpenPositionCheckPlain tx:", submitTx.hash);
    console.log(`  Waiting ${SUBMIT_WAIT_MS / 1000}s for CoFHE dispatcher...`);
    await new Promise(r => setTimeout(r, SUBMIT_WAIT_MS));

    // Phase B — finalize once dispatcher publishes the decrypt result
    try {
      const openTx = await fheRouter.finalizeOpenPositionPlain(
        INDEX_TOKEN,
        true,  // hasLiqPlain — vault liquidity check result
        "0x",  // hasLiqSig  — CoFHE dispatcher signature (empty on mock)
      );
      const receipt = await openTx.wait();
      console.log("\nfinalizeOpenPositionPlain tx:", openTx.hash);
      console.log("Gas used:", receipt?.gasUsed.toString());

      const iface = new ethers.Interface(FHE_ROUTER_ABI);
      for (const log of receipt?.logs ?? []) {
        try {
          const parsed = iface.parseLog({ topics: [...log.topics], data: log.data });
          if (parsed?.name === "OpenPosition") {
            positionId = parsed.args.positionKey;
            console.log("\nEncryption check — position opened (collateral wrapped to euint64):");
            console.log("  positionId:", positionId);
            console.log("  plain ERC-20 was wrapped on-chain to euint64 before storage");
          }
        } catch {}
      }
      break;

    } catch (err: any) {
      if (isDecryptNotReady(err)) {
        console.log(`  "decrypt not ready" — dispatcher hasn't published yet.`);
        console.log(`  Waiting ${RETRY_INTERVAL_MS / 1000}s before retry...`);
        await new Promise(r => setTimeout(r, RETRY_INTERVAL_MS));
      } else {
        throw err;
      }
    }
  }

  if (!positionId) {
    console.error("\nFailed to open position after max retries.");
    console.error("The CoFHE dispatcher may not be active on this network.");
    process.exit(1);
  }

  // ── CLOSE: request (user) → finalize (keeper/owner) ──────────────────────

  console.log("\n[Close — user requests plain ERC-20 payout]");
  const reqTx = await fheRouter.requestClosePlainPayout(positionId);
  await reqTx.wait();
  console.log("requestClosePlainPayout tx:", reqTx.hash);

  // Keeper finalizes — same wallet on testnet.
  // On real CoFHE: finalAmount/sizePlain/collateralPlain come from the dispatcher.
  console.log("\n[Close — keeper finalizes plain ERC-20 payout]");
  const finTx = await fheRouter.finalizeClosePlainPayout(
    positionId,
    FINAL_AMOUNT,      // finalAmount
    "0x",              // finalAmountSig
    SIZE_PLAIN,        // sizePlain
    "0x",              // sizeSig
    PLAIN_COLLATERAL,  // collateralPlain
    "0x",              // collateralSig
    IS_LONG,           // isLongPlain
  );
  const finReceipt = await finTx.wait();
  console.log("finalizeClosePlainPayout tx:", finTx.hash);

  const iface = new ethers.Interface(FHE_ROUTER_ABI);
  for (const log of finReceipt?.logs ?? []) {
    try {
      const parsed = iface.parseLog({ topics: [...log.topics], data: log.data });
      if (parsed?.name === "PlainPayoutSettled") {
        console.log("\nPlainPayoutSettled (full flow verified):");
        console.log("  trader:", parsed.args.trader);
        console.log("  amount:", parsed.args.amount.toString(), "(plain ERC-20 units)");
        console.log("  Position was stored encrypted throughout — only entry/exit are plain.");
      }
    } catch {}
  }
}

main().catch(console.error);
