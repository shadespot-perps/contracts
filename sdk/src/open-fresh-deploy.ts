import { ethers, Wallet, JsonRpcProvider, Contract } from "ethers";
import { createCofheConfig, createCofheClient } from "@cofhe/sdk/node";
import { Ethers6Adapter } from "@cofhe/sdk/adapters";
import { arbSepolia } from "@cofhe/sdk/chains";
import { Encryptable } from "@cofhe/sdk";
import { RPC_URL, PRIVATE_KEY, INDEX_TOKEN } from "./config";

// Fresh deployment addresses (from your terminal logs).
const ADDR = {
  ROUTER: "0x3F476E2D46eA857aD82DA28c41a15d336F3bA83D",
  VAULT: "0xF522f386046644b359472E05340BB692751C5A37",
  ORACLE: "0x372cCb135c97e106eD44701e6170Ac4C06Dc3F72",
  TOKEN: "0xe3843689B78709463a77Faa30d7A2Df72f56163b",
};

const ROUTER_ABI = [
  "function addLiquidity((uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature) encAmount) external",
  "function submitOpenPositionCheck(address token,(uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature) encCollateral,(uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature) encLeverage,(uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature) encIsLong) external",
  "function finalizeOpenPosition(address token,(uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature) encCollateral,(uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature) encLeverage,(uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature) encIsLong,bool hasLiqPlain,bytes hasLiqSig) external returns (bytes32)",
  "event OpenPosition(bytes32 indexed positionKey, address indexed trader)",
];

const VAULT_ABI = [
  "function pendingLiqCheck(address trader) external view returns (bytes32 hasLiq, bytes32 eSize)",
];

const ORACLE_ABI = ["function setPrice(address token, uint256 price) external"];

const TOKEN_ABI = [
  "function setOperator(address operator, uint48 until) external",
  "function isOperator(address holder, address spender) external view returns (bool)",
  "function mint(address to, uint64 amount) external",
];

const PRICE_8DEC = BigInt(process.env.PRICE_8DEC ?? "320000000000"); // $3200.00
const LP_AMOUNT = BigInt(process.env.LP_AMOUNT ?? "50000000"); // provides vault liquidity
const COLLATERAL = BigInt(process.env.COLLATERAL ?? "10000000"); // 10_000_000
const LEVERAGE = BigInt(process.env.LEVERAGE ?? "5");
const IS_LONG = (process.env.IS_LONG ?? "true").toLowerCase() === "true";
const MINT_AMOUNT = BigInt(process.env.MINT_AMOUNT ?? "200000000"); // mock token only

const MAX_DECRYPT_RETRIES = Number(process.env.MAX_DECRYPT_RETRIES ?? "30");
const DECRYPT_RETRY_MS = Number(process.env.DECRYPT_RETRY_MS ?? "10000");

const CHAIN_ID = 421614; // Arbitrum Sepolia
const SECURITY_ZONE = Number(process.env.SECURITY_ZONE ?? "0");

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function decryptWithPermit(cofheClient: any, ctHash: bigint, label: string): Promise<{ value: bigint; sig: string }> {
  const permit = await cofheClient.permits.getOrCreateSelfPermit();
  const ctHashHex = "0x" + ctHash.toString(16).padStart(64, "0");
  let lastErr: unknown;

  for (let i = 1; i <= MAX_DECRYPT_RETRIES; i++) {
    try {
      const res = await cofheClient.decryptForTx(ctHashHex).withPermit(permit).execute();
      console.log(`  ${label}: ${res.decryptedValue.toString()}`);
      return { value: res.decryptedValue as bigint, sig: res.signature as string };
    } catch (err) {
      lastErr = err;
      if (i < MAX_DECRYPT_RETRIES) {
        await new Promise((r) => setTimeout(r, DECRYPT_RETRY_MS));
      }
    }
  }

  throw new Error(`decryptForTx failed for ${label}: ${String(lastErr)}`);
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function encryptOnArbSepolia(cofheClient: any, inputs: any[]) {
  return await cofheClient
    .encryptInputs(inputs)
    .setChainId(CHAIN_ID)
    .setSecurityZone(SECURITY_ZONE)
    .execute();
}

async function main() {
  const provider = new JsonRpcProvider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);

  const router = new Contract(ADDR.ROUTER, ROUTER_ABI, wallet);
  const vault = new Contract(ADDR.VAULT, VAULT_ABI, wallet);
  const oracle = new Contract(ADDR.ORACLE, ORACLE_ABI, wallet);
  const token = new Contract(ADDR.TOKEN, TOKEN_ABI, wallet);

  const cofheConfig = createCofheConfig({ supportedChains: [arbSepolia] });
  const cofheClient = createCofheClient(cofheConfig);
  const { publicClient, walletClient } = await Ethers6Adapter(provider, wallet);
  await cofheClient.connect(publicClient, walletClient);

  console.log("Wallet:", wallet.address);
  console.log("Router:", ADDR.ROUTER);
  console.log("Vault :", ADDR.VAULT);
  console.log("Oracle:", ADDR.ORACLE);
  console.log("Token :", ADDR.TOKEN);
  console.log("Index :", INDEX_TOKEN);
  console.log("CoFHE chainId:", CHAIN_ID, "securityZone:", SECURITY_ZONE);

  // Mint for MockFHEToken deployments (no access control).
  try {
    const mintTx = await token.mint(wallet.address, MINT_AMOUNT);
    await mintTx.wait();
    console.log("Mint tx:", mintTx.hash);
  } catch {
    console.log("Mint skipped (token may not expose mint).");
  }

  // FHERC20 operator grant for router.
  const isOp = await token.isOperator(wallet.address, ADDR.ROUTER);
  if (!isOp) {
    const until = Math.floor(Date.now() / 1000) + 86400 * 30;
    const opTx = await token.setOperator(ADDR.ROUTER, until);
    await opTx.wait();
    console.log("setOperator tx:", opTx.hash);
  } else {
    console.log("Operator already granted.");
  }

  // Oracle price (8 decimals).
  const oracleTx = await oracle.setPrice(INDEX_TOKEN, PRICE_8DEC);
  await oracleTx.wait();
  console.log("setPrice tx:", oracleTx.hash);

  // Add liquidity so the reserve-liquidity check can pass.
  console.log("\naddLiquidity...");
  const [encLpAmount] = await encryptOnArbSepolia(cofheClient, [Encryptable.uint64(LP_AMOUNT)]);
  const liqTx = await router.addLiquidity(encLpAmount);
  await liqTx.wait();
  console.log("addLiquidity tx:", liqTx.hash);

  // Open position (two-phase).
  console.log("\nsubmitOpenPositionCheck...");
  const [encCollateral, encLeverage, encIsLong] = await encryptOnArbSepolia(cofheClient, [
    Encryptable.uint64(COLLATERAL),
    Encryptable.uint64(LEVERAGE),
    Encryptable.bool(IS_LONG),
  ]);

  const submitTx = await router.submitOpenPositionCheck(INDEX_TOKEN, encCollateral, encLeverage, encIsLong);
  await submitTx.wait();
  console.log("submitOpenPositionCheck tx:", submitTx.hash);

  const pending = await vault.pendingLiqCheck(wallet.address);
  const hasLiqHandle = BigInt(pending.hasLiq);
  const hasLiq = await decryptWithPermit(cofheClient, hasLiqHandle, "hasLiq");

  console.log("finalizeOpenPosition...");
  const openTx = await router.finalizeOpenPosition(
    INDEX_TOKEN,
    encCollateral,
    encLeverage,
    encIsLong,
    hasLiq.value !== 0n,
    hasLiq.sig,
  );
  const rc = await openTx.wait();
  console.log("finalizeOpenPosition tx:", openTx.hash);

  let positionKey = "";
  const iface = new ethers.Interface(ROUTER_ABI);
  for (const log of rc?.logs ?? []) {
    try {
      const parsed = iface.parseLog({ topics: [...log.topics], data: log.data });
      if (parsed?.name === "OpenPosition") positionKey = parsed.args.positionKey;
    } catch {}
  }

  if (!positionKey) throw new Error("Position key not found in OpenPosition event.");
  console.log("positionKey:", positionKey);
}

main().catch((err) => {
  console.error("Open flow failed:", err?.message ?? err);
  process.exit(1);
});

