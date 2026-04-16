/**
 * pool2-redeploy.ts
 *
 * Runs the DeployPool2Only forge script, then reads the broadcast JSON and
 * automatically patches POOL2 addresses in config.ts.
 *
 * Usage:
 *   npm run pool2:redeploy
 *
 * After it finishes:
 *   npm run pool2:setup          — re-grant setOperator on the new FHERouter
 *   npm run pool2:add-liquidity  — re-seed the new FHEVault
 *   npm run pool2:open           — open a position
 */

import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

// Load .env from the contracts root (one level up from sdk/)
const envPath = path.resolve(__dirname, "../../.env");
dotenv.config({ path: envPath });

const RPC_URL    = process.env.ARBITRUM_SEPOLIA_RPC_URL!;
const PRIVATE_KEY = process.env.PRIVATE_KEY!;
const FHE_TOKEN  = process.env.COLLATERAL_TOKEN_FHE;

if (!RPC_URL || !PRIVATE_KEY) {
  console.error("Missing ARBITRUM_SEPOLIA_RPC_URL or PRIVATE_KEY in .env");
  process.exit(1);
}

if (!FHE_TOKEN) {
  console.error(
    "Missing COLLATERAL_TOKEN_FHE in .env\n" +
    "Set it to the existing FHE token address (e.g. 0x2Efc2A6E950b711e18d387C6F9fd8091754b5eA0)"
  );
  process.exit(1);
}

// Arbitrum Sepolia chain ID
const CHAIN_ID = "421614";

const CONTRACTS_ROOT = path.resolve(__dirname, "../../");
const BROADCAST_JSON = path.join(
  CONTRACTS_ROOT,
  "broadcast",
  "DeployPool2Only.s.sol",
  CHAIN_ID,
  "run-latest.json",
);
const CONFIG_TS = path.resolve(__dirname, "config.ts");

// ── 1. Run forge script ────────────────────────────────────────────────────

console.log("Running DeployPool2Only forge script...\n");

const forgeCmd = [
  "forge script script/DeployPool2Only.s.sol",
  `--rpc-url "${RPC_URL}"`,
  "--broadcast",
  `--private-key "${PRIVATE_KEY}"`,
].join(" ");

try {
  execSync(forgeCmd, {
    cwd: CONTRACTS_ROOT,
    stdio: "inherit",
    env: {
      ...process.env,
      COLLATERAL_TOKEN_FHE: FHE_TOKEN,
    },
  });
} catch (e) {
  console.error("\nForge script failed. Check the output above.");
  process.exit(1);
}

// ── 2. Parse broadcast JSON for deployed addresses ─────────────────────────

if (!fs.existsSync(BROADCAST_JSON)) {
  console.error(`Broadcast JSON not found: ${BROADCAST_JSON}`);
  process.exit(1);
}

const broadcast = JSON.parse(fs.readFileSync(BROADCAST_JSON, "utf8"));

// Only pick CREATE transactions (deployments)
const deployments: Record<string, string> = {};
for (const tx of broadcast.transactions) {
  if (tx.transactionType === "CREATE" && tx.contractName && tx.contractAddress) {
    // Last deployment wins if the same contract name appears multiple times
    deployments[tx.contractName] = tx.contractAddress;
  }
}

const oracle      = deployments["PriceOracle"];
const fundingMgr  = deployments["FundingRateManager"];
const fheVault    = deployments["FHEVault"];
const positionMgr = deployments["PositionManager"];
const orderMgr    = deployments["OrderManager"];
const liqMgr      = deployments["LiquidationManager"];
const fheRouter   = deployments["FHERouter"];

const missing = [
  ["PriceOracle",        oracle],
  ["FundingRateManager", fundingMgr],
  ["FHEVault",           fheVault],
  ["PositionManager",    positionMgr],
  ["OrderManager",       orderMgr],
  ["LiquidationManager", liqMgr],
  ["FHERouter",          fheRouter],
].filter(([, addr]) => !addr).map(([name]) => name);

if (missing.length > 0) {
  console.error(`Could not find addresses for: ${missing.join(", ")}`);
  console.error("Check the broadcast JSON:", BROADCAST_JSON);
  process.exit(1);
}

// ── 3. Patch POOL2 block in config.ts ─────────────────────────────────────

let config = fs.readFileSync(CONFIG_TS, "utf8");

// Replace each address line inside the POOL2 object using targeted regex
const replacements: [RegExp, string][] = [
  [/(ORACLE:\s+)"[^"]*"/, `$1"${oracle}"`],
  [/(FUNDING_MANAGER:\s+)"[^"]*"/, `$1"${fundingMgr}"`],
  [/(FHE_VAULT:\s+)"[^"]*"/, `$1"${fheVault}"`],
  [/(POSITION_MANAGER:\s+)"[^"]*"/, `$1"${positionMgr}"`],
  [/(ORDER_MANAGER:\s+)"[^"]*"/, `$1"${orderMgr}"`],
  [/(LIQUIDATION_MGR:\s+)"[^"]*"/, `$1"${liqMgr}"`],
  [/(FHE_ROUTER:\s+)"[^"]*"/, `$1"${fheRouter}"`],
];

// Only replace inside the POOL2 block to avoid touching POOL1 keys of same name
const pool2Start = config.indexOf("export const POOL2");
if (pool2Start === -1) {
  console.error("Could not find 'export const POOL2' in config.ts");
  process.exit(1);
}

const pool2Block = config.slice(pool2Start);
let patchedBlock = pool2Block;
for (const [regex, replacement] of replacements) {
  patchedBlock = patchedBlock.replace(regex, replacement);
}
config = config.slice(0, pool2Start) + patchedBlock;

fs.writeFileSync(CONFIG_TS, config);

// ── 4. Summary ─────────────────────────────────────────────────────────────

console.log("\n=== config.ts updated with new Pool 2 addresses ===");
console.log("  ORACLE:           ", oracle);
console.log("  FUNDING_MANAGER:  ", fundingMgr);
console.log("  FHE_VAULT:        ", fheVault);
console.log("  POSITION_MANAGER: ", positionMgr);
console.log("  ORDER_MANAGER:    ", orderMgr);
console.log("  LIQUIDATION_MGR:  ", liqMgr);
console.log("  FHE_ROUTER:       ", fheRouter);
console.log("\nNext steps:");
console.log("  npm run pool2:setup          # re-grant setOperator on the new FHERouter");
console.log("  npm run pool2:add-liquidity  # re-seed the new FHEVault");
console.log("  npm run pool2:open           # open a position");
