import { ethers, Wallet, JsonRpcProvider, Contract, EventLog } from "ethers";
import { createCofheConfig, createCofheClient } from "@cofhe/sdk/node";
import { Ethers6Adapter } from "@cofhe/sdk/adapters";
import { arbSepolia } from "@cofhe/sdk/chains";
import { Encryptable } from "@cofhe/sdk";
import { RPC_URL, PRIVATE_KEY, INDEX_TOKEN, POOL2 } from "./config";

const ROUTER_ABI = [
  "function addLiquidity((uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature) encAmount) external",
  "function submitOpenPositionCheck(address token,(uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature) encCollateral,(uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature) encLeverage,(uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature) encIsLong) external",
  "function finalizeOpenPosition(address token,(uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature) encCollateral,(uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature) encLeverage,(uint256 ctHash,uint8 securityZone,uint8 utype,bytes signature) encIsLong,bool hasLiqPlain,bytes hasLiqSig) external returns (bytes32)",
  "function requestClosePosition(bytes32 positionId) external",
  "event OpenPosition(bytes32 indexed positionKey, address indexed trader)",
];

const POSITION_MANAGER_ABI = [
  "function getMyPosition(bytes32 key) external view returns ((address owner,address indexToken,bytes32 size,bytes32 collateral,bytes32 entryPrice,bytes32 entryFundingRateBiased,bytes32 eLeverage,bytes32 isLong,bool exists,uint256 leverage))",
  "function finalizeClosePosition(bytes32 positionKey,uint256 finalAmount,bytes finalAmountSignature,uint256 sizePlain,bytes sizeSignature,uint256 collateralPlain,bytes collateralSignature,bool isLongPlain) external",
  "event CloseRequested(bytes32 indexed positionKey, address indexed trader, bytes32 finalAmountHandle, bytes32 sizeHandle)",
  "event CloseFinalized(bytes32 indexed positionKey, address indexed trader, bytes32 finalAmountHandle)",
];

const VAULT_ABI = [
  "function pendingLiqCheck(address trader) external view returns (bytes32 hasLiq, bytes32 eSize)",
];

const ORACLE_ABI = [
  "function setPrice(address token, uint256 price) external",
];

const TOKEN_ABI = [
  "function setOperator(address operator, uint48 until) external",
  "function isOperator(address holder, address spender) external view returns (bool)",
  "function mint(address to, uint64 amount) external",
];

const ADDR = {
  ROUTER: process.env.FHE_ROUTER ?? POOL2.FHE_ROUTER,
  POSITION_MANAGER: process.env.POSITION_MANAGER ?? POOL2.POSITION_MANAGER,
  ORACLE: process.env.ORACLE ?? POOL2.ORACLE,
  TOKEN: process.env.COLLATERAL_TOKEN_FHE ?? POOL2.FHE_TOKEN,
};

const PRICE = BigInt(process.env.PRICE_8DEC ?? "200000000000");
const LP_AMOUNT = BigInt(process.env.LP_AMOUNT ?? "50000000");
const COLLATERAL = BigInt(process.env.COLLATERAL ?? "10000000");
const LEVERAGE = BigInt(process.env.LEVERAGE ?? "5");
const IS_LONG = (process.env.IS_LONG ?? "true").toLowerCase() === "true";
const MINT_AMOUNT = BigInt(process.env.MINT_AMOUNT ?? "100000000");
const MAX_DECRYPT_RETRIES = Number(process.env.MAX_DECRYPT_RETRIES ?? "20");
const DECRYPT_RETRY_MS = Number(process.env.DECRYPT_RETRY_MS ?? "10000");

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function decryptWithPermit(cofheClient: any, ctHash: bigint, label: string): Promise<{ value: bigint; sig: string }> {
  const permit = await cofheClient.permits.getOrCreateSelfPermit();
  const ctHashHex = "0x" + ctHash.toString(16).padStart(64, "0");
  let lastErr: unknown;

  for (let i = 1; i <= MAX_DECRYPT_RETRIES; i++) {
    try {
      const res = await cofheClient
        .decryptForTx(ctHashHex)
        .withPermit(permit)
        .execute();
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

async function main() {
  const provider = new JsonRpcProvider(RPC_URL);
  const wallet = new Wallet(PRIVATE_KEY, provider);

  const router = new Contract(ADDR.ROUTER, ROUTER_ABI, wallet);
  const pm = new Contract(ADDR.POSITION_MANAGER, POSITION_MANAGER_ABI, wallet);
  const oracle = new Contract(ADDR.ORACLE, ORACLE_ABI, wallet);
  const token = new Contract(ADDR.TOKEN, TOKEN_ABI, wallet);
  const vault = new Contract(POOL2.FHE_VAULT, VAULT_ABI, wallet);

  const cofheConfig = createCofheConfig({ supportedChains: [arbSepolia] });
  const cofheClient = createCofheClient(cofheConfig);
  const { publicClient, walletClient } = await Ethers6Adapter(provider, wallet);
  await cofheClient.connect(publicClient, walletClient);

  console.log("Wallet:", wallet.address);
  console.log("Router:", ADDR.ROUTER);
  console.log("PositionManager:", ADDR.POSITION_MANAGER);
  console.log("Oracle:", ADDR.ORACLE);
  console.log("Collateral token:", ADDR.TOKEN);
  console.log("Index token:", INDEX_TOKEN);
  console.log("NOTE: this script assumes wallet is both trader and finalizer.");

  // Optional mint for MockFHEToken deployments.
  try {
    const mintTx = await token.mint(wallet.address, MINT_AMOUNT);
    await mintTx.wait();
    console.log("Mint tx:", mintTx.hash);
  } catch {
    console.log("Mint skipped (token may not expose mint in this deployment).");
  }

  const isOp = await token.isOperator(wallet.address, ADDR.ROUTER);
  if (!isOp) {
    const until = Math.floor(Date.now() / 1000) + 86400 * 30;
    const opTx = await token.setOperator(ADDR.ROUTER, until);
    await opTx.wait();
    console.log("setOperator tx:", opTx.hash);
  } else {
    console.log("Operator already granted.");
  }

  // Keep oracle fresh.
  const oracleTx = await oracle.setPrice(INDEX_TOKEN, PRICE);
  await oracleTx.wait();
  console.log("setPrice tx:", oracleTx.hash);

  // 1) LP add liquidity
  console.log("\n[1/4] addLiquidity...");
  const [encLpAmount] = await cofheClient.encryptInputs([Encryptable.uint64(LP_AMOUNT)]).execute();
  const liqTx = await router.addLiquidity(encLpAmount);
  await liqTx.wait();
  console.log("addLiquidity tx:", liqTx.hash);

  // 2) Open position (two-phase)
  console.log("\n[2/4] submitOpenPositionCheck...");
  const [encCollateral, encLeverage, encIsLong] = await cofheClient
    .encryptInputs([Encryptable.uint64(COLLATERAL), Encryptable.uint64(LEVERAGE), Encryptable.bool(IS_LONG)])
    .execute();

  const submitOpenTx = await router.submitOpenPositionCheck(
    INDEX_TOKEN,
    encCollateral,
    encLeverage,
    encIsLong,
  );
  await submitOpenTx.wait();
  console.log("submitOpenPositionCheck tx:", submitOpenTx.hash);

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
  const openRc = await openTx.wait();
  console.log("finalizeOpenPosition tx:", openTx.hash);

  let positionKey = "";
  const routerIface = new ethers.Interface(ROUTER_ABI);
  for (const log of openRc?.logs ?? []) {
    try {
      const parsed = routerIface.parseLog({ topics: [...log.topics], data: log.data });
      if (parsed?.name === "OpenPosition") {
        positionKey = parsed.args.positionKey;
      }
    } catch {}
  }
  if (!positionKey) throw new Error("Position key not found in OpenPosition event.");
  console.log("positionKey:", positionKey);

  // 3) Request close
  console.log("\n[3/4] requestClosePosition...");
  const reqCloseTx = await router.requestClosePosition(positionKey);
  const reqCloseRc = await reqCloseTx.wait();
  console.log("requestClosePosition tx:", reqCloseTx.hash);

  // 4) Decrypt + finalize close
  console.log("\n[4/4] decrypt handles + finalizeClosePosition...");
  const pmIface = new ethers.Interface(POSITION_MANAGER_ABI);
  let finalAmountHandle = 0n;
  let sizeHandle = 0n;
  for (const log of reqCloseRc?.logs ?? []) {
    try {
      const parsed = pmIface.parseLog({ topics: [...log.topics], data: log.data });
      if (parsed?.name === "CloseRequested") {
        finalAmountHandle = BigInt(parsed.args.finalAmountHandle);
        sizeHandle = BigInt(parsed.args.sizeHandle);
      }
    } catch {}
  }
  if (finalAmountHandle === 0n || sizeHandle === 0n) {
    throw new Error("CloseRequested handles not found in requestClosePosition receipt.");
  }

  const p = await pm.getMyPosition(positionKey);
  const collateralHandle = BigInt(p.collateral);

  const finalAmount = await decryptWithPermit(cofheClient, finalAmountHandle, "finalAmount");
  const size = await decryptWithPermit(cofheClient, sizeHandle, "size");
  const collateral = await decryptWithPermit(cofheClient, collateralHandle, "collateral");

  const finalizeTx = await pm.finalizeClosePosition(
    positionKey,
    finalAmount.value,
    finalAmount.sig,
    size.value,
    size.sig,
    collateral.value,
    collateral.sig,
    false,
  );
  await finalizeTx.wait();
  console.log("finalizeClosePosition tx:", finalizeTx.hash);

  console.log("\nHappy-path flow complete.");
}

main().catch((err) => {
  console.error("Flow failed:", err?.message ?? err);
  process.exit(1);
});
