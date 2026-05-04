/**
 * decrypt-tx-test.ts
 *
 * Purpose: Determine whether CoFHE Threshold Network decrypt failures are
 * due to permit/allowance vs endpoint/origin blocking.
 *
 * Usage:
 *   npm run decrypt:tx-test -- <ctHash>
 *
 * Examples:
 *   npm run decrypt:tx-test -- 0xabc... (bytes32 handle)
 *   npm run decrypt:tx-test -- 123456789 (decimal)
 */

import { createCofheConfig, createCofheClient } from "@cofhe/sdk/node";
import { chains } from "@cofhe/sdk/chains";
import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrumSepolia } from "viem/chains";

import { RPC_URL, PRIVATE_KEY } from "./config";

const CHAIN_ID = 421614; // Arbitrum Sepolia

function parseCtHash(input: string): bigint {
  const v = input.trim();
  if (v.startsWith("0x") || v.startsWith("0X")) return BigInt(v);
  return BigInt(v);
}

async function main() {
  const arg = process.argv[2];
  if (!arg) {
    console.error("Missing ctHash argument.");
    console.error("Usage: npm run decrypt:tx-test -- <ctHash>");
    process.exit(1);
  }

  const ctHash = parseCtHash(arg);
  const account = privateKeyToAccount(PRIVATE_KEY as `0x${string}`);

  const publicClient = createPublicClient({
    chain: arbitrumSepolia,
    transport: http(RPC_URL),
  });

  const walletClient = createWalletClient({
    account,
    chain: arbitrumSepolia,
    transport: http(RPC_URL),
  });

  const config = createCofheConfig({
    supportedChains: [chains.arbSepolia],
  });
  const client = createCofheClient(config);

  await client.connect(publicClient as any, walletClient as any);

  console.log("=== CoFHE decryptForTx test ===");
  console.log("ctHash:     ", `0x${ctHash.toString(16).padStart(64, "0")}`);
  console.log("chainId:    ", CHAIN_ID);
  console.log("account:    ", account.address);
  console.log("tn endpoint:", chains.arbSepolia.thresholdNetworkUrl);

  // 1) withPermit (self)
  console.log("\n--- Attempt A: decryptForTx WITH self permit ---");
  try {
    const permit = await client.permits.getOrCreateSelfPermit();
    const res = await client
      .decryptForTx(ctHash)
      .setChainId(CHAIN_ID)
      .withPermit(permit)
      .execute();
    console.log("OK");
    console.log("decryptedValue:", res.decryptedValue.toString());
    console.log("signature:     ", res.signature);
  } catch (e: any) {
    console.error("FAILED");
    console.error(String(e?.message ?? e));
    if (e?.context) {
      console.error("context:", JSON.stringify(e.context, null, 2));
    }
    if (e?.cause) {
      console.error("cause:", String(e.cause?.message ?? e.cause));
    }
    if (String(e?.message ?? "").includes("HTTP 403")) {
      console.error("-> Looks like endpoint-level blocking (403), not a typical permit mismatch.");
    }
  }

  // 2) withoutPermit (global allow)
  console.log("\n--- Attempt B: decryptForTx WITHOUT permit (global allow) ---");
  try {
    const res = await client
      .decryptForTx(ctHash)
      .setChainId(CHAIN_ID)
      .withoutPermit()
      .execute();
    console.log("OK");
    console.log("decryptedValue:", res.decryptedValue.toString());
    console.log("signature:     ", res.signature);
  } catch (e: any) {
    console.error("FAILED");
    console.error(String(e?.message ?? e));
    if (e?.context) {
      console.error("context:", JSON.stringify(e.context, null, 2));
    }
    if (e?.cause) {
      console.error("cause:", String(e.cause?.message ?? e.cause));
    }
    if (String(e?.message ?? "").includes("HTTP 403")) {
      console.error("-> Looks like endpoint-level blocking (403), not a typical allow/permit mismatch.");
    }
  }
}

main().catch((e) => {
  console.error("Fatal:", e);
  process.exit(1);
});

