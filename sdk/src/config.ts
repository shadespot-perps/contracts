import * as dotenv from "dotenv";
import * as path from "path";

// Load from contracts/.env (sdk/ lives inside contracts/)
dotenv.config({ path: path.resolve(__dirname, "../../.env") });

export const CHAIN_ID = Number(process.env.CHAIN_ID ?? "421614"); // default arbitrumSepolia

function pickRpcUrl(chainId: number): string | undefined {
  if (process.env.RPC_URL) return process.env.RPC_URL;
  if (chainId === 421614) return process.env.ARBITRUM_SEPOLIA_RPC_URL;
  if (chainId === 11155111) return process.env.ETH_SEPOLIA_RPC_URL;
  if (chainId === 84532) return process.env.BASE_SEPOLIA_RPC_URL;
  return process.env.ARBITRUM_SEPOLIA_RPC_URL;
}

export const RPC_URL     = pickRpcUrl(CHAIN_ID)!;
export const PRIVATE_KEY = process.env.PRIVATE_KEY!;
export const INDEX_TOKEN = process.env.INDEX_TOKEN ?? ((DEPLOYMENTS as Record<number, any>)[CHAIN_ID] ?? DEPLOYMENTS[421614]).INDEX_TOKEN;

if (!RPC_URL || !PRIVATE_KEY || !INDEX_TOKEN) {
  throw new Error(
    "Missing env vars. Check contracts/.env for PRIVATE_KEY and a RPC URL (RPC_URL or *_SEPOLIA_RPC_URL)."
  );
}

// ── Deployed addresses (3 test networks) ────────────────────────────────────

export const DEPLOYMENTS = {
  421614: {
    name: "arbitrumSepolia",
    INDEX_TOKEN: "0x980B62Da83eFf3D4576C647993b0c1D7faf17c73",
    FHE_TOKEN:        "0xebfad581cae1cfd8ab8f73e06e47491acad80a92",
    PLAIN_UNDERLYING: "0xc02db0300f51966aa698b2ff9c57a9098f2be75d",
    ORACLE:           "0x83dab41639664325e92c25688e72a4f0dd0c5f44",
    FUNDING_MANAGER:  "0xae38162272ead1841d2daaccb61201cc373155ae",
    FHE_VAULT:        "0xe3bb5227af76420018fc8b83b62b8986a53fc6b5",
    POSITION_MANAGER: "0x1567dbbcd3ad98974b3489094342ca7827d48e29",
    ORDER_MANAGER:    "0xa6b0c3aa876782d4e9dea48bddaf7d605bb7f8ef",
    LIQUIDATION_MGR:  "0xaa3438e9d8aa8dec4be2f6a6f9ff1f2728179c1f",
    FHE_ROUTER:       "0xb0ef97bb069f9b6fefb246de0688f8072d8c6671",
    FINALIZER:        "0x2b284c179a65709fC823711e6D76134E55a63798",
  },
  11155111: {
    name: "sepolia",
    INDEX_TOKEN: "0xf531B8F309Be94191af87605CfBf600D71C2cFe0",
    FHE_TOKEN:        "0xfa89331592f2a226207cff13240d9d41bd2d60f5",
    PLAIN_UNDERLYING: "0xe533e7fafff450ed287471c465c48d421a59b6cb",
    ORACLE:           "0x924d6e0f2996fc6517516b3d50ac7782b08e679a",
    FUNDING_MANAGER:  "0xd9f29b1da10e3835f155e016364ef2d320d686e8",
    FHE_VAULT:        "0xb672f9690d09eb0d62393a9128edd2c8e0322b63",
    POSITION_MANAGER: "0x4f88d2ffebb4b8493fa4460546934a48fd46f455",
    ORDER_MANAGER:    "0x76977bcf817fc8720b42a80406bbed4d2006e6d7",
    LIQUIDATION_MGR:  "0xf2472217b9ad364143d51d38930b56a23bc55777",
    FHE_ROUTER:       "0xc44043bcb49505105675414643c53009c97f98b0",
    FINALIZER:        "0x2b284c179a65709fC823711e6D76134E55a63798",
  },
  84532: {
    name: "baseSepolia",
    INDEX_TOKEN: "0x4200000000000000000000000000000000000006",
    FHE_TOKEN:        "0x54866fca9eca5bee34cf3c65ec032196594352a6",
    PLAIN_UNDERLYING: "0x7837d65620731972970b7f6cc2eda4b46428f7aa",
    ORACLE:           "0xf251e5d86b101b2662d88e366f9d81475ad9eba7",
    FUNDING_MANAGER:  "0x575fe7d38c479f65d3329e64dca1dbb599c0b640",
    FHE_VAULT:        "0x2c3ac3af650923593fae8e2b5d1f6f2d2709a1e7",
    POSITION_MANAGER: "0x6c9e3d0376d6479267886fb28cb2c6bc7d684480",
    ORDER_MANAGER:    "0x5d2e88801434b1d8fdc585c942bc8c0f430d1571",
    LIQUIDATION_MGR:  "0xca146c6c3eb2f5776a222c3849e96994e7c0eded",
    FHE_ROUTER:       "0xbc5c5f0b0b50bc6ff5540de5a6bff7977959ad52",
    FINALIZER:        "0x2b284c179a65709fC823711e6D76134E55a63798",
  },
} as const;

export const ACTIVE = (DEPLOYMENTS as Record<number, any>)[CHAIN_ID] ?? DEPLOYMENTS[421614];

// Allow overriding the index token via env, else pick from deployment.
export const ACTIVE_INDEX_TOKEN = INDEX_TOKEN;

// Pool 1 (USDC / ETH)
export const POOL1 = {
  USDC:             "0x5925bDEAd1a5A08203E0dC333dd10832daf20248",
  ORACLE:           "0x072b0ca5A419D8293A81Cd9f0167CB29aD9E813A",
  FUNDING_MANAGER:  "0x34a7DC8015f5705deEf2f5641e4894b41b9E9Cb9",
  VAULT:            "0x1ee156AefDFE6D29af80eFAEAA0715909253cBC0",
  POSITION_MANAGER: "0xa3A13968D9157b46F78eff4CCcC53add47E6B68c",
  ORDER_MANAGER:    "0xc4e195De483A0E43446D9907e3De2445b99C4e2E",
  LIQUIDATION_MGR:  "0xab833e4258dB2F994795339412c86Df42144c531",
  ROUTER:           "0xaaD5cd9ab30117cef2001B19b4fcA9F0C0D76e02",
};

// Pool 2 (FHE Token / ETH) — active chain
export const POOL2 = {
  FHE_TOKEN:        ACTIVE.FHE_TOKEN,
  PLAIN_UNDERLYING: ACTIVE.PLAIN_UNDERLYING,
  ORACLE:           ACTIVE.ORACLE,
  FUNDING_MANAGER:  ACTIVE.FUNDING_MANAGER,
  FHE_VAULT:        ACTIVE.FHE_VAULT,
  POSITION_MANAGER: ACTIVE.POSITION_MANAGER,
  ORDER_MANAGER:    ACTIVE.ORDER_MANAGER,
  LIQUIDATION_MGR:  ACTIVE.LIQUIDATION_MGR,
  FHE_ROUTER:       ACTIVE.FHE_ROUTER,
  FINALIZER:        ACTIVE.FINALIZER,
};

// CoFHE TaskManager on Arbitrum Sepolia
export const TASK_MANAGER =
  process.env.TASK_MANAGER ??
  (CHAIN_ID === 421614 ? "0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9" : "");

if (!TASK_MANAGER) {
  throw new Error("Missing env var TASK_MANAGER for this CHAIN_ID");
}

// Encryption type constants (matches ICofhe.sol)
export const ENC_TYPE = {
  EBOOL:    0,
  EUINT8:   2,
  EUINT16:  3,
  EUINT32:  4,
  EUINT64:  5,
  EUINT128: 6,
  EADDRESS: 7,
} as const;
