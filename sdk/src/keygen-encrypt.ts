/**
 * keygen-encrypt.ts
 *
 * Fully LOCAL — no network, no RPC needed.
 *
 * Steps:
 *   1. Generate a TFHE keypair  (clientKey + publicKey)
 *   2. Generate a SealingKey    (x25519 keypair for reading encrypted results back)
 *   3. Encrypt uint values      (uint8, uint32, uint64, uint128) using the publicKey
 *   4. Print ciphertext (hex) + proof metadata for each value
 *
 * The encrypted .data bytes are what you pass as calldata to any contract
 * function accepting InEuint8 / InEuint32 / InEuint64 / InEuint128.
 */

// eslint-disable-next-line @typescript-eslint/no-require-imports
const { createTfheKeypair } = require("fhenixjs/dist/sdk/tfhe/tfhe");
import { GenerateSealingKey } from "fhenixjs";
import * as fs from "fs";
import * as path from "path";

// ── Values to encrypt (edit these) ───────────────────────────────────────────

const ENCRYPT_TARGETS = [
  { label: "collateral (uint64)", type: "uint64",  value: 10_000_000n  },
  { label: "leverage   (uint32)", type: "uint32",  value: 5            },
  { label: "isLong     (bool)",   type: "bool",    value: true         },
  { label: "size       (uint128)",type: "uint128", value: 50_000_000n  },
];

// ── Low-level encrypt helpers using node-tfhe directly ───────────────────────

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function encryptWithKey(publicKey: any, type: string, value: bigint | number | boolean): Uint8Array {
  // node-tfhe compact encryption — each type has its own class
  // CompactFheUint* produces ciphertext with an embedded ZK proof of plaintext knowledge
  const {
    CompactFheBool,
    CompactFheUint8,
    CompactFheUint16,
    CompactFheUint32,
    CompactFheUint64,
    CompactFheUint128,
  } = require("node-tfhe");

  switch (type) {
    case "bool":
      return CompactFheBool.encrypt_with_compact_public_key(value as boolean, publicKey).serialize();
    case "uint8":
      return CompactFheUint8.encrypt_with_compact_public_key(Number(value), publicKey).serialize();
    case "uint16":
      return CompactFheUint16.encrypt_with_compact_public_key(Number(value), publicKey).serialize();
    case "uint32":
      return CompactFheUint32.encrypt_with_compact_public_key(Number(value), publicKey).serialize();
    case "uint64":
      return CompactFheUint64.encrypt_with_compact_public_key(BigInt(value as bigint), publicKey).serialize();
    case "uint128":
      return CompactFheUint128.encrypt_with_compact_public_key(BigInt(value as bigint), publicKey).serialize();
    default:
      throw new Error(`Unsupported type: ${type}`);
  }
}

function toHex(bytes: Uint8Array): string {
  return "0x" + Buffer.from(bytes).toString("hex");
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log("=== Step 1: Generate TFHE Keypair (local, no network) ===\n");

  const { clientKey, publicKey } = createTfheKeypair();

  const publicKeyBytes  = publicKey.serialize();
  const clientKeyBytes  = clientKey.serialize();

  console.log("clientKey  :", clientKeyBytes.length, "bytes");
  console.log("publicKey  :", publicKeyBytes.length, "bytes");
  console.log("publicKey  :", toHex(publicKeyBytes).slice(0, 66) + "...");

  // ── Step 2: Generate SealingKey (x25519 — for reading encrypted results) ──

  console.log("\n=== Step 2: Generate SealingKey (x25519) ===\n");

  const sealingKey = await GenerateSealingKey();
  console.log("sealingKey.publicKey :", sealingKey.publicKey);
  console.log("sealingKey.privateKey:", sealingKey.privateKey);
  console.log("(share publicKey with contract; keep privateKey to unseal results)");

  // ── Step 3: Encrypt values ─────────────────────────────────────────────────

  console.log("\n=== Step 3: Encrypt Values ===\n");

  const results: Record<string, string> = {};

  for (const { label, type, value } of ENCRYPT_TARGETS) {
    const ciphertext = encryptWithKey(publicKey, type, value);
    const hex        = toHex(ciphertext);
    results[label]   = hex;

    console.log(`${label}`);
    console.log(`  plaintext  : ${value}`);
    console.log(`  type       : ${type}`);
    console.log(`  ciphertext : ${hex.slice(0, 66)}...`);
    console.log(`  size       : ${ciphertext.length} bytes`);
    console.log();
  }

  // ── Step 4: Write keys + ciphertexts to disk ──────────────────────────────

  const outDir  = path.resolve(__dirname, "../../.cofhe-local");
  fs.mkdirSync(outDir, { recursive: true });

  fs.writeFileSync(
    path.join(outDir, "keys.json"),
    JSON.stringify({
      sealingPublicKey:  sealingKey.publicKey,
      sealingPrivateKey: sealingKey.privateKey,
      tfhePublicKeyHex:  toHex(publicKeyBytes),
      note: "NEVER commit clientKey or sealingPrivateKey to git",
    }, null, 2)
  );

  fs.writeFileSync(
    path.join(outDir, "ciphertexts.json"),
    JSON.stringify(results, null, 2)
  );

  console.log("=== Output ===");
  console.log("Keys saved to      : contracts/.cofhe-local/keys.json");
  console.log("Ciphertexts saved  : contracts/.cofhe-local/ciphertexts.json");

  // ── Step 5: Show how to pass ciphertext as calldata ───────────────────────

  console.log("\n=== Step 5: Pass ciphertext to contract (cast example) ===\n");

  const collateralHex = results["collateral (uint64)"];
  console.log("cast send <ROUTER> \\");
  console.log('  "openPosition(address,(bytes),(bytes),(bytes))" \\');
  console.log("  $INDEX_TOKEN \\");
  console.log(`  "(${collateralHex.slice(0, 18)}...)" \\   # InEuint64 collateral`);
  console.log('  "(0x...)" \\                               # InEuint32 leverage');
  console.log('  "(0x...)" \\                               # InEuint8  isLong');
  console.log("  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \\");
  console.log("  --private-key $PRIVATE_KEY");
  console.log("\n(Note: current Router.sol takes plain uint256 — encrypted calldata");
  console.log(" is needed only if the contract function signature uses InEuint* params)");
}

main().catch(console.error);
