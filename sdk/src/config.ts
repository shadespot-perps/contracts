import * as dotenv from "dotenv";
import * as path from "path";

// Load from contracts/.env (sdk/ lives inside contracts/)
dotenv.config({ path: path.resolve(__dirname, "../../.env") });

export const RPC_URL     = process.env.ARBITRUM_SEPOLIA_RPC_URL!;
export const PRIVATE_KEY = process.env.PRIVATE_KEY!;
export const INDEX_TOKEN = process.env.INDEX_TOKEN!;

if (!RPC_URL || !PRIVATE_KEY || !INDEX_TOKEN) {
  throw new Error("Missing env vars. Check contracts/.env for ARBITRUM_SEPOLIA_RPC_URL, PRIVATE_KEY, INDEX_TOKEN");
}

// ── Deployed addresses (Arbitrum Sepolia) ────────────────────────────────────

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

// Pool 2 (FHE Token / ETH)
export const POOL2 = {
  // Fresh deployment (May 07, 2026)
  FHE_TOKEN:        "0xDFF61c2e5fFB08bdfEd3520a37c86A2c976e3283",
  ORACLE:           "0x5557D65E67124bA5b3ea3dAE17e9B473006bCd4E",
  FUNDING_MANAGER:  "0xa5e08198e0E6268413D398b908Afe303b4aB4623",
  FHE_VAULT:        "0x96D1Cc159775457EE7c03FF98683959F10FCc91C",
  POSITION_MANAGER: "0xa9147bc8274a87FC63c8BEa1dBBF07c62cd557F1",
  ORDER_MANAGER:    "0x81cA357f55b6C4763f2f5E1f11308D8e09457FA0",
  LIQUIDATION_MGR:  "0x921c6e48F5a698BaC282aB6B022aa124dFF225c6",
  FHE_ROUTER:       "0x2Df347fd32cED9CD019C752E999f9ABf6E4613e4",
};

// CoFHE TaskManager on Arbitrum Sepolia
export const TASK_MANAGER = "0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9";

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
