/**
 * encrypt.ts
 *
 * Two approaches to produce encrypted inputs for CoFHE contracts:
 *
 *   A) FhenixClient.encrypt_uint64()  — real ZKP-backed ciphertext (needs CoFHE RPC)
 *   B) buildCtHash()                  — trivialEncrypt handle (testnet only, no ZKP)
 *
 * Current Router.sol / FHERouter.sol take plain uint256 and call FHE.asEuint64()
 * internally, so you don't need to encrypt off-chain for them today.
 * Use Approach A when a contract accepts InEuint64 { bytes data; int32 securityZone; }.
 */

import { ethers, Wallet, JsonRpcProvider } from "ethers";
import { FhenixClient, EncryptedUint64 } from "fhenixjs";
import { RPC_URL, PRIVATE_KEY, ENC_TYPE } from "./config";

// ─────────────────────────────────────────────────────────────────────────────
// Approach A — FhenixClient (ZKP-backed, needs CoFHE public key from RPC)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Encrypt a uint64 using the CoFHE network's public key.
 * Returns an InEuint64-compatible struct { data, securityZone }.
 *
 * The returned value can be passed directly as calldata to any contract
 * function that accepts `InEuint64 calldata`.
 */
export async function encryptUint64(value: bigint | number) {
  const provider = new JsonRpcProvider(RPC_URL);
  const client   = new FhenixClient({ provider });

  // Fetches the CoFHE network public key and encrypts client-side
  const encrypted = await client.encrypt_uint64(BigInt(value));
  return encrypted; // { data: Uint8Array }
}

/**
 * Encrypt a uint128 (used for position size / collateral fields).
 */
export async function encryptUint128(value: bigint | number) {
  const provider = new JsonRpcProvider(RPC_URL);
  const client   = new FhenixClient({ provider });
  return client.encrypt_uint128(BigInt(value));
}

/**
 * Encrypt a bool (used for isLong field).
 */
export async function encryptBool(value: boolean) {
  const provider = new JsonRpcProvider(RPC_URL);
  const client   = new FhenixClient({ provider });
  return client.encrypt_bool(value);
}

/**
 * ABI-encode an EncryptedUint64 for use as calldata.
 * Solidity:  struct InEuint64 { bytes data; }  — or pass as raw bytes
 */
export function encodeInEuint64(encrypted: EncryptedUint64): string {
  return ethers.AbiCoder.defaultAbiCoder().encode(
    ["bytes"],
    [encrypted.data]
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Approach B — trivialEncrypt handle (testnet only, no ZKP)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Build a ctHash matching the CoFHE TaskManager's trivialEncrypt handle format.
 * Format: keccak256(seed)[0:30] || enc_type (1 byte) || security_zone (1 byte)
 *
 * Use this to construct ctHash values for getDecryptResultSafe() lookups.
 */
export function buildCtHash(seed: string, encType: number, securityZone = 0): bigint {
  const hash   = BigInt(ethers.keccak256(ethers.toUtf8Bytes(seed)));
  const masked = hash & (~BigInt(0xFFFF));
  return masked | (BigInt(encType) << BigInt(8)) | BigInt(securityZone & 0xFF);
}

/**
 * Compute the 76-byte message hash the CoFHE dispatcher signs.
 * Layout: result(32) || enc_type(4) || chain_id(8) || ct_hash(32)
 */
export function computeDecryptResultHash(
  result:  bigint,
  encType: number,
  chainId: bigint,
  ctHash:  bigint
): string {
  const buf = new Uint8Array(76);

  const rb = ethers.getBytes(ethers.zeroPadValue(ethers.toBeHex(result), 32));
  buf.set(rb, 0);

  const et = new Uint8Array(4);
  et[0] = (encType >> 24) & 0xFF; et[1] = (encType >> 16) & 0xFF;
  et[2] = (encType >>  8) & 0xFF; et[3] =  encType        & 0xFF;
  buf.set(et, 32);

  const cb = new Uint8Array(8);
  for (let i = 7; i >= 0; i--)
    cb[7 - i] = Number((chainId >> BigInt(i * 8)) & BigInt(0xFF));
  buf.set(cb, 36);

  const ch = ethers.getBytes(ethers.zeroPadValue(ethers.toBeHex(ctHash), 32));
  buf.set(ch, 44);

  return ethers.keccak256(buf);
}

/**
 * Sign a decrypt result (mirrors the TN dispatcher's sign_prehash).
 * Returns raw 65-byte hex string (no 0x).
 */
export async function signDecryptResult(
  signer:  Wallet,
  result:  bigint,
  encType: number,
  chainId: bigint,
  ctHash:  bigint
): Promise<string> {
  const msgHash = computeDecryptResultHash(result, encType, chainId, ctHash);
  const sig     = signer.signingKey.sign(msgHash);
  return sig.r.slice(2) + sig.s.slice(2) + sig.v.toString(16).padStart(2, "0");
}

// ─────────────────────────────────────────────────────────────────────────────
// Demo
// ─────────────────────────────────────────────────────────────────────────────

async function main() {
  const provider = new JsonRpcProvider(RPC_URL);
  const wallet   = new Wallet(PRIVATE_KEY, provider);
  const chainId  = (await provider.getNetwork()).chainId;

  console.log("=== Approach A — FhenixClient (ZKP-backed) ===");
  try {
    const enc = await encryptUint64(10_000_000);
    console.log("encrypted.data length:", enc.data.length, "bytes");
    console.log("ABI-encoded calldata :");
    console.log(encodeInEuint64(enc));
  } catch (e: any) {
    console.log("Note: CoFHE public key fetch may fail if RPC doesn't expose eth_fhenix_getPublicKey");
    console.log("Error:", e.message);
  }

  console.log("\n=== Approach B — trivialEncrypt handle ===");
  const value   = BigInt(10_000_000);
  const encType = ENC_TYPE.EUINT64;
  const ctHash  = buildCtHash(`collateral:${value}`, encType);
  console.log("ctHash  :", "0x" + ctHash.toString(16));

  const msgHash = computeDecryptResultHash(value, encType, chainId, ctHash);
  console.log("msgHash :", msgHash);

  const rawSig = await signDecryptResult(wallet, value, encType, chainId, ctHash);
  console.log("sig     : 0x" + rawSig);
}

main().catch(console.error);
